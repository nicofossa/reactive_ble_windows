import 'dart:async';
import 'dart:typed_data';

import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart';
import 'package:win_ble/win_ble.dart';
import 'package:win_ble/win_file.dart';

class ReactiveBleWindowsPlatform extends ReactiveBlePlatform {
  // Scan related variables
  StreamController<int>? _startScanStreamController;
  List<Uuid> _scanWithServices = [];
  Map<String, String> _nameCache = {};

  // Connection related variables
  final _connectionsStreamController =
      StreamController<ConnectionStateUpdate>.broadcast();
  Map<String, StreamSubscription> _connectionsSubscriptionsMap = {};
  Map<String, StreamController<int>> _connectStreamControllersMap = {};

  // Characteristics related variables
  StreamController<CharacteristicValue>? _charateristicsStreamController;
  StreamSubscription? _characteristicStreamSubscriptions;

  ReactiveBleWindowsPlatform();

  @override
  Future<void> initialize() async {
    await WinBle.initialize(serverPath: await WinServer.path());
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
    _nameCache.clear();
    WinBle.startScanning();
    _startScanStreamController = StreamController(
        onListen: () {},
        onCancel: () {
          WinBle.stopScanning();
          _startScanStreamController?.close();
          _startScanStreamController = null;
        });
    _startScanStreamController!.sink
        .add(0); // Hack: this is needed to start the scan stream
    return _startScanStreamController!.stream;
  }

  @override
  Stream<ScanResult> get scanStream {
    return WinBle.scanStream.where((event) {
      if (_scanWithServices.isEmpty) return true;
      return event.serviceUuids
          .map<Uuid>((dynamic e) =>
              Uuid.parse(e.toString().replaceAll("{", "").replaceAll("}", "")))
          .any((element) => _scanWithServices.contains(element));
    }).map((event) {
      // Caching the name, otherwise in some circumstances the scan can respond with
      // the same device many times and sometimes the device doesn't have the name
      // TODO: check if this behavior is present in other fields of the scan
      String name = event.name;
      if (name.isEmpty) {
        name = _nameCache[event.address] ?? "";
      } else {
        _nameCache[event.address] = name;
      }

      return ScanResult(
          result:
              Result<DiscoveredDevice, GenericFailure<ScanFailure>?>.success(
                  DiscoveredDevice(
        id: event.address,
        name: name,
        serviceData: const {},
        manufacturerData: event.manufacturerData,
        rssi: int.tryParse(event.rssi) ?? 0,
        serviceUuids: event.serviceUuids
            .map<Uuid>((dynamic e) => Uuid.parse(
                e.toString().replaceAll("{", "").replaceAll("}", "")))
            .toList(growable: false),
        // TODO: handle connectable property
      )));
    });
  }

  Stream<void> connectToDevice(
    String id,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  ) {
    if (_connectionsSubscriptionsMap.containsKey(id)) {
      print("Trying to connect to an already connected device! Bug?");
      _connectionsSubscriptionsMap.remove(id);
    }

    WinBle.connect(id);

    _connectionsSubscriptionsMap[id] = WinBle.connectionStreamOf(id).listen(
      (e) => _onConnectionStreamEvent(id, e),
    );
    _connectStreamControllersMap[id] = StreamController<int>(
      onCancel: () => _onConnectCancel(id),
      onListen: () => _connectStreamControllersMap[id]
          ?.add(1), // To start the listen from the interface
    );

    return _connectStreamControllersMap[id]!.stream;
  }

  FutureOr<void> _onConnectCancel(String id) {
    _connectStreamControllersMap[id]?.close();
    _connectStreamControllersMap.remove(id);
  }

  _onConnectionStreamEvent(String id, bool isConnected) {
    if (!_connectionsSubscriptionsMap.containsKey(id)) {
      print("Stream already closed in onConnectionStreamEvent!");
      return;
    }

    final state = isConnected
        ? DeviceConnectionState.connected
        : DeviceConnectionState.disconnected;

    _connectionsStreamController.add(ConnectionStateUpdate(
      deviceId: id,
      connectionState: state,
      failure: null,
    ));
  }

  Stream<ConnectionStateUpdate> get connectionUpdateStream {
    return _connectionsStreamController.stream;
  }

  @override
  Future<void> disconnectDevice(String deviceId) async {
    await _connectStreamControllersMap[deviceId]?.close();
    _connectStreamControllersMap.remove(deviceId);

    await _connectionsSubscriptionsMap[deviceId]?.cancel();
    _connectionsSubscriptionsMap.remove(deviceId);

    await WinBle.disconnect(deviceId);
  }

  Future<List<DiscoveredService>> discoverServices(String deviceId,
      {bool forceRefresh = true}) async {
    final servicesList = <DiscoveredService>[];

    final discoveredServices =
        await WinBle.discoverServices(deviceId, forceRefresh: forceRefresh);

    for (final service in discoveredServices) {
      try {
        List<BleCharacteristic> bleCharacteristics =
            await WinBle.discoverCharacteristics(
                address: deviceId,
                serviceId: service,
                forceRefresh: forceRefresh);

        final serviceUuid =
            Uuid.parse(service.replaceAll("{", "").replaceAll("}", ""));

        servicesList.add(DiscoveredService(
            serviceId: serviceUuid,
            serviceInstanceId: service,
            characteristicIds: bleCharacteristics
                .map((e) =>
                    Uuid.parse(e.uuid.replaceAll("{", "").replaceAll("}", "")))
                .toList(growable: false),
            characteristics: bleCharacteristics
                .map((e) => DiscoveredCharacteristic(
                    characteristicId: Uuid.parse(
                        e.uuid.replaceAll("{", "").replaceAll("}", "")),
                    characteristicInstanceId: e.uuid,
                    serviceId: serviceUuid,
                    isReadable: e.properties.read ?? false,
                    isWritableWithResponse: e.properties.write ?? false,
                    isWritableWithoutResponse:
                        e.properties.writeWithoutResponse ?? false,
                    isNotifiable: e.properties.notify ?? false,
                    isIndicatable: e.properties.indicate ?? false))
                .toList(growable: false)));
      } catch (_) {
        print("Ignoring faulty service $service!");
      }
    }

    return servicesList;
  }

  Future<List<DiscoveredService>> getDiscoverServices(String deviceId) {
    return discoverServices(deviceId, forceRefresh: false);
  }

  Stream<void> readCharacteristic(
      CharacteristicInstance characteristic) async* {
    final data = await WinBle.read(
      address: characteristic.deviceId,
      serviceId: characteristic.serviceInstanceId,
      characteristicId: characteristic.characteristicInstanceId,
    );
    yield 0;
    _charateristicsStreamController?.add(CharacteristicValue(
      characteristic: characteristic,
      result: Result.success(data),
    ));
  }

  Future<WriteCharacteristicInfo> writeCharacteristicWithResponse(
    CharacteristicInstance characteristic,
    List<int> value,
  ) async {
    return await _writeCharacteristicImpl(characteristic, value,
        withResponse: true);
  }

  Future<WriteCharacteristicInfo> writeCharacteristicWithoutResponse(
    CharacteristicInstance characteristic,
    List<int> value,
  ) async {
    return await _writeCharacteristicImpl(characteristic, value,
        withResponse: false);
  }

  Stream<CharacteristicValue> get charValueUpdateStream {
    if (_charateristicsStreamController == null) {
      _charateristicsStreamController =
          StreamController<CharacteristicValue>.broadcast(
              onCancel: _onCharacteristicStreamControllerClosed);
      _characteristicStreamSubscriptions =
          WinBle.characteristicValueStream.listen((event) {
        final parsed = _characteristicFromWinBleStream(event);
        _charateristicsStreamController!.add(parsed);
      });
    }
    return _charateristicsStreamController!.stream;
  }

  Stream<void> subscribeToNotifications(
      CharacteristicInstance characteristic) async* {
    await WinBle.subscribeToCharacteristic(
      address: characteristic.deviceId,
      serviceId: characteristic.serviceInstanceId,
      characteristicId: characteristic.characteristicInstanceId,
    );
    yield 0;
  }

  Future<void> stopSubscribingToNotifications(
      CharacteristicInstance characteristic) async {
    await WinBle.unSubscribeFromCharacteristic(
      address: characteristic.deviceId,
      serviceId: characteristic.serviceInstanceId,
      characteristicId: characteristic.characteristicInstanceId,
    );
  }

  // Static interfaces
  static void registerWith() {
    ReactiveBlePlatform.instance = ReactiveBleWindowsPlatform();
  }

  Future<WriteCharacteristicInfo> _writeCharacteristicImpl(
    CharacteristicInstance characteristic,
    List<int> value, {
    required bool withResponse,
  }) async {
    try {
      await WinBle.write(
          address: characteristic.deviceId,
          service: characteristic.serviceInstanceId,
          characteristic: characteristic.characteristicInstanceId,
          data: Uint8List.fromList(value),
          writeWithResponse: withResponse);
      return WriteCharacteristicInfo(
          characteristic: characteristic, result: Result.success(Unit()));
    } catch (e) {
      return WriteCharacteristicInfo(
          characteristic: characteristic,
          result: Result.failure(GenericFailure(
              code: WriteCharacteristicFailure.unknown,
              message: 'Write characteristic failed!')));
    }
  }

  FutureOr<void> _onCharacteristicStreamControllerClosed() {
    _characteristicStreamSubscriptions?.cancel();
    _characteristicStreamSubscriptions = null;

    _charateristicsStreamController?.close();
    _charateristicsStreamController = null;
  }

  CharacteristicValue _characteristicFromWinBleStream(event) {
    return CharacteristicValue(
        characteristic: CharacteristicInstance(
          deviceId: event["address"],
          characteristicId: Uuid.parse(event["characteristicId"]
              .toString()
              .replaceAll("{", "")
              .replaceAll("}", "")),
          characteristicInstanceId: event["characteristicId"],
          serviceId: Uuid.parse(event["serviceId"]
              .toString()
              .replaceAll("{", "")
              .replaceAll("}", "")),
          serviceInstanceId: event["serviceId"],
        ),
        result: Result.success((event["value"] as List).cast<int>()));
  }

  Future<int> requestMtuSize(String deviceId, int? mtu) async {
    return await WinBle.getMaxMtuSize(deviceId);
  }
}
