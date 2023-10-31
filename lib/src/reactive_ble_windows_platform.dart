import 'dart:async';

import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart';
import 'package:win_ble/win_ble.dart';
import 'package:win_ble/win_file.dart';

class ReactiveBleWindowsPlatform extends ReactiveBlePlatform {
  StreamController<int>? _startScanStreamController;
  List<Uuid> _scanWithServices = [];

  ReactiveBleWindowsPlatform();

  @override
  Future<void> initialize() async {
    print("Initializing...");
    await WinBle.initialize(serverPath: await WinServer.path);
    print("Initialized!");
  }

  @override
  Future<void> deinitialize() async {
    WinBle.dispose();
  }

  @override
  Stream<BleStatus> get bleStatusStream => WinBle.bleState.map((event) {
        switch (event) {
          case BleState.On:
            return BleStatus.ready;
          case BleState.Off:
            return BleStatus.poweredOff;
          case BleState.Unknown:
            return BleStatus.unknown;
          case BleState.Disabled:
            return BleStatus.poweredOff;
          case BleState.Unsupported:
            return BleStatus.unsupported;
        }
      });

  @override
  Stream<void> scanForDevices({
    required List<Uuid> withServices,
    required ScanMode scanMode,
    required bool requireLocationServicesEnabled,
  }) {
    if (_startScanStreamController != null) {
      _startScanStreamController?.close();
      print("Scanning with an already scanning interface!");
    }
    _scanWithServices = List.of(withServices);
    print("Starting scan!");
    WinBle.startScanning();
    _startScanStreamController = StreamController(onListen: () {
      print("Someone is listening!");
    }, onCancel: () {
      print("Subscription canceled!");
      WinBle.stopScanning();
      _startScanStreamController?.close();
      _startScanStreamController = null;
    });
    _startScanStreamController!.sink.add(0); // Hack: this is needed to start the scan stream
    return _startScanStreamController!.stream;
  }

  @override
  Stream<ScanResult> get scanStream {
    print("Got stream!");
    return WinBle.scanStream.where((event) {
      if (_scanWithServices.isEmpty) return true;
      return event.serviceUuids
          .map<Uuid>((dynamic e) => Uuid.parse(e.toString().replaceAll("{", "").replaceAll("}", "")))
          .any((element) => _scanWithServices.contains(element));
    }).map((event) => ScanResult(
            result: Result<DiscoveredDevice, GenericFailure<ScanFailure>?>.success(DiscoveredDevice(
          id: event.address,
          name: event.name,
          serviceData: const {},
          manufacturerData: event.manufacturerData,
          rssi: int.tryParse(event.rssi) ?? 0,
          serviceUuids: event.serviceUuids
              .map<Uuid>((dynamic e) => Uuid.parse(e.toString().replaceAll("{", "").replaceAll("}", "")))
              .toList(growable: false),
        ))));
  }

  Stream<ConnectionStateUpdate> get connectionUpdateStream {
    return StreamController<ConnectionStateUpdate>().stream;
  }

  static void registerWith() {
  print("Register with called");
    ReactiveBlePlatform.instance = ReactiveBleWindowsPlatform();
  }
}
