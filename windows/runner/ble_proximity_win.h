#ifndef RUNNER_BLE_PROXIMITY_WIN_H_
#define RUNNER_BLE_PROXIMITY_WIN_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

struct BleAdapterStatusWin {
  bool supported = false;
  bool adapter_available = false;
  bool adapter_enabled = false;
  bool scanning = false;
  bool advertising = false;
  std::string reason = "no_ble_hardware";
};

struct BlePeerDiscoveryWin {
  std::string address;
  std::string ephemeral_id;
  std::string name;
  int port = 53317;
  int capabilities = 0;
  int rssi = -70;
  std::string proximity_zone = "near";
};

class BleProximityWin {
 public:
  using PeerCallback = std::function<void(const BlePeerDiscoveryWin&)>;

  explicit BleProximityWin(PeerCallback on_peer);
  ~BleProximityWin();

  BleAdapterStatusWin GetStatus() const;
  bool StartDiscovery(int port, const std::vector<uint8_t>& ephemeral_id);
  void StopDiscovery();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_BLE_PROXIMITY_WIN_H_
