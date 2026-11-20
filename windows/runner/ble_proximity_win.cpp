#include "ble_proximity_win.h"

#include <unknwn.h>
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>

#include <cstdio>
#include <mutex>
#include <thread>
#include <unordered_map>

namespace {

constexpr uint16_t kManufacturerId = 0x4D44;  // 'MD'
constexpr uint8_t kProtocolVersion = 0x01;
constexpr double kRssiAlpha = 0.35;

std::string FormatBtAddress(uint64_t addr) {
  char buf[24];
  std::snprintf(
      buf, sizeof(buf), "%02X:%02X:%02X:%02X:%02X:%02X",
      static_cast<unsigned>((addr >> 40) & 0xFF),
      static_cast<unsigned>((addr >> 32) & 0xFF),
      static_cast<unsigned>((addr >> 24) & 0xFF),
      static_cast<unsigned>((addr >> 16) & 0xFF),
      static_cast<unsigned>((addr >> 8) & 0xFF),
      static_cast<unsigned>(addr & 0xFF));
  return std::string(buf);
}

std::string BytesToHex(const std::vector<uint8_t>& bytes) {
  static constexpr char kHex[] = "0123456789ABCDEF";
  std::string out;
  out.reserve(bytes.size() * 2);
  for (uint8_t b : bytes) {
    out.push_back(kHex[(b >> 4) & 0xF]);
    out.push_back(kHex[b & 0xF]);
  }
  return out;
}

std::string ZoneForRssi(int rssi) {
  if (rssi >= -55) return "immediate";
  if (rssi >= -75) return "near";
  return "far";
}

}  // namespace

struct BleProximityWin::Impl {
  PeerCallback on_peer;
  std::mutex mu;
  bool scanning = false;
  bool advertising = false;
  std::string local_ephemeral_hex;
  std::unordered_map<uint64_t, double> rssi_ema;

  winrt::Windows::Devices::Bluetooth::Advertisement::
      BluetoothLEAdvertisementWatcher watcher{nullptr};
  winrt::event_token received_token{};
  winrt::Windows::Devices::Bluetooth::Advertisement::
      BluetoothLEAdvertisementPublisher publisher{nullptr};
};

BleProximityWin::BleProximityWin(PeerCallback on_peer)
    : impl_(std::make_unique<Impl>()) {
  impl_->on_peer = std::move(on_peer);
}

BleProximityWin::~BleProximityWin() {
  StopDiscovery();
}

BleAdapterStatusWin BleProximityWin::GetStatus() const {
  BleAdapterStatusWin st;
  {
    std::lock_guard<std::mutex> lk(impl_->mu);
    st.scanning = impl_->scanning;
    st.advertising = impl_->advertising;
  }

  std::thread([&st]() {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      auto adapter =
          winrt::Windows::Devices::Bluetooth::BluetoothAdapter::GetDefaultAsync()
              .get();
      if (!adapter || !adapter.IsLowEnergySupported()) {
        st.supported = false;
        st.adapter_available = false;
        st.adapter_enabled = false;
        st.reason = "no_ble_hardware";
        return;
      }
      st.supported = true;
      st.adapter_available = true;
      auto radio = adapter.GetRadioAsync().get();
      if (radio &&
          radio.State() ==
              winrt::Windows::Devices::Radios::RadioState::On) {
        st.adapter_enabled = true;
        st.reason = "ready";
      } else {
        st.adapter_enabled = false;
        st.reason = "bluetooth_disabled";
      }
    } catch (...) {
      st.supported = false;
      st.adapter_available = false;
      st.adapter_enabled = false;
      st.reason = "no_ble_hardware";
    }
  }).join();

  return st;
}

bool BleProximityWin::StartDiscovery(int port,
                                     const std::vector<uint8_t>& ephemeral_id) {
  auto status = GetStatus();
  if (!status.adapter_available || !status.adapter_enabled) {
    return false;
  }

  StopDiscovery();

  try {
    using namespace winrt::Windows::Devices::Bluetooth::Advertisement;
    using namespace winrt::Windows::Storage::Streams;

    std::lock_guard<std::mutex> lk(impl_->mu);
    impl_->local_ephemeral_hex = BytesToHex(ephemeral_id);

    // 1. Start BLE Manufacturer Advertisement (0x4D44)
    std::vector<uint8_t> payload;
    payload.reserve(4 + ephemeral_id.size());
    payload.push_back(kProtocolVersion);
    payload.push_back(0x03);  // BLE + LAN capabilities
    payload.push_back(static_cast<uint8_t>((port >> 8) & 0xFF));
    payload.push_back(static_cast<uint8_t>(port & 0xFF));
    payload.insert(payload.end(), ephemeral_id.begin(), ephemeral_id.end());

    DataWriter writer;
    writer.WriteBytes(payload);
    BluetoothLEManufacturerData mfg_data;
    mfg_data.CompanyId(kManufacturerId);
    mfg_data.Data(writer.DetachBuffer());

    BluetoothLEAdvertisement adv;
    adv.ManufacturerData().Append(mfg_data);

    BluetoothLEAdvertisementPublisher publisher(adv);
    publisher.Start();
    impl_->publisher = publisher;
    impl_->advertising = true;

    // 2. Start BLE Advertisement Watcher filtered on ManufacturerId 0x4D44
    BluetoothLEAdvertisementWatcher watcher;
    watcher.ScanningMode(BluetoothLEScanningMode::Active);
    BluetoothLEManufacturerData filter_mfg;
    filter_mfg.CompanyId(kManufacturerId);
    watcher.AdvertisementFilter().Advertisement().ManufacturerData().Append(
        filter_mfg);

    Impl* raw_impl = impl_.get();
    impl_->received_token = watcher.Received(
        [raw_impl](BluetoothLEAdvertisementWatcher const&,
                   BluetoothLEAdvertisementReceivedEventArgs const& args) {
          try {
            auto mfg_list = args.Advertisement().ManufacturerData();
            for (auto const& item : mfg_list) {
              if (item.CompanyId() != kManufacturerId) continue;
              auto buf = item.Data();
              auto reader = DataReader::FromBuffer(buf);
              uint32_t len = buf.Length();
              if (len < 20) continue;
              std::vector<uint8_t> bytes(len);
              reader.ReadBytes(bytes);

              int caps = bytes[1];
              int peer_port = (static_cast<int>(bytes[2]) << 8) | bytes[3];
              std::vector<uint8_t> eph(bytes.begin() + 4, bytes.begin() + 20);
              std::string eph_hex = BytesToHex(eph);

              PeerCallback cb;
              int smoothed_rssi = args.RawSignalStrengthInDBm();
              {
                std::lock_guard<std::mutex> g(raw_impl->mu);
                if (eph_hex == raw_impl->local_ephemeral_hex) return;
                uint64_t bt_addr = args.BluetoothAddress();
                auto it = raw_impl->rssi_ema.find(bt_addr);
                double ema = (it == raw_impl->rssi_ema.end())
                                 ? static_cast<double>(smoothed_rssi)
                                 : kRssiAlpha * smoothed_rssi +
                                       (1.0 - kRssiAlpha) * it->second;
                raw_impl->rssi_ema[bt_addr] = ema;
                smoothed_rssi = static_cast<int>(ema);
                cb = raw_impl->on_peer;
              }

              if (cb) {
                BlePeerDiscoveryWin peer;
                peer.address = FormatBtAddress(args.BluetoothAddress());
                peer.ephemeral_id = eph_hex;
                auto local_name = args.Advertisement().LocalName();
                peer.name = local_name.empty() ? "Nearby Device"
                                               : winrt::to_string(local_name);
                peer.port = peer_port;
                peer.capabilities = caps;
                peer.rssi = smoothed_rssi;
                peer.proximity_zone = ZoneForRssi(smoothed_rssi);
                cb(peer);
              }
            }
          } catch (...) {}
        });

    watcher.Start();
    impl_->watcher = watcher;
    impl_->scanning = true;
    return true;
  } catch (...) {
    StopDiscovery();
    return false;
  }
}

void BleProximityWin::StopDiscovery() {
  std::lock_guard<std::mutex> lk(impl_->mu);
  if (impl_->watcher) {
    try {
      impl_->watcher.Received(impl_->received_token);
      impl_->watcher.Stop();
    } catch (...) {}
    impl_->watcher = nullptr;
  }
  if (impl_->publisher) {
    try {
      impl_->publisher.Stop();
    } catch (...) {}
    impl_->publisher = nullptr;
  }
  impl_->scanning = false;
  impl_->advertising = false;
  impl_->rssi_ema.clear();
}
