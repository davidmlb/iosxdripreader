/**
 Copyright (C) 2016  Johan Degraeve
 
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/gpl.txt>.
 
 */
package services
{
	import com.distriqt.extension.bluetoothle.AuthorisationStatus;
	import com.distriqt.extension.bluetoothle.BluetoothLE;
	import com.distriqt.extension.bluetoothle.BluetoothLEState;
	import com.distriqt.extension.bluetoothle.events.BluetoothLEEvent;
	import com.distriqt.extension.bluetoothle.events.CharacteristicEvent;
	import com.distriqt.extension.bluetoothle.events.PeripheralEvent;
	import com.distriqt.extension.bluetoothle.objects.Characteristic;
	import com.distriqt.extension.bluetoothle.objects.Peripheral;
	import com.freshplanet.ane.AirBackgroundFetch.BackgroundFetch;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.TimerEvent;
	import flash.utils.ByteArray;
	import flash.utils.Endian;
	import flash.utils.Timer;
	
	import G5Model.AuthChallengeRxMessage;
	import G5Model.AuthChallengeTxMessage;
	import G5Model.AuthRequestTxMessage;
	import G5Model.AuthStatusRxMessage;
	import G5Model.BatteryInfoRxMessage;
	import G5Model.BatteryInfoTxMessage;
	import G5Model.SensorRxMessage;
	import G5Model.SensorTxMessage;
	import G5Model.TransmitterStatus;
	
	import Utilities.HM10Attributes;
	import Utilities.Trace;
	import Utilities.UniqueId;
	
	import avmplus.FLASH10_FLAGS;
	
	import databaseclasses.BlueToothDevice;
	import databaseclasses.CommonSettings;
	
	import distriqtkey.DistriqtKey;
	
	import events.BlueToothServiceEvent;
	import events.SettingsServiceEvent;
	
	import model.TransmitterDataG5Packet;
	import model.TransmitterDataXBridgeBeaconPacket;
	import model.TransmitterDataXBridgeDataPacket;
	import model.TransmitterDataXdripDataPacket;
	
	import views.HomeView;
	
	/**
	 * all functionality related to bluetooth connectivity<br>
	 * init function must be called once immediately at start of the application<br>
	 * <br>
	 * to get info about connectivity status, new transmitter data ... check BluetoothServiceEvent  create listeners for the events<br>
	 * BluetoothService itself is not doing anything with the data received from the bluetoothdevice, also not checking the transmit id, it just passes the information via 
	 * dispatching<br>
	 */
	public class BluetoothService extends EventDispatcher
	{
		
		private static var _instance:BluetoothService = new BluetoothService();
		
		public static function get instance():BluetoothService
		{
			return _instance;
		}
		
		private static var _activeBluetoothPeripheral:Peripheral;
		
		private static var initialStart:Boolean = true;
		
		private static const MAX_SCAN_TIME_IN_SECONDS:int = 15;
		private static var discoverServiceOrCharacteristicTimer:Timer;
		private static const DISCOVER_SERVICES_OR_CHARACTERISTICS_RETRY_TIME_IN_SECONDS:int = 1;
		private static const MAX_RETRY_DISCOVER_SERVICES_OR_CHARACTERISTICS:int = 5;
		private static var amountOfDiscoverServicesOrCharacteristicsAttempt:int = 0;
		
		private static var awaitingConnect:Boolean = false;
		
		private static const srcNameTable:Array = [ '0', '1', '2', '3', '4', '5', '6', '7',
			'8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
			'G', 'H', 'J', 'K', 'L', 'M', 'N', 'P',
			'Q', 'R', 'S', 'T', 'U', 'W', 'X', 'Y' ];
		
		private static const uuids_G4_Service:Vector.<String> = new <String>[HM10Attributes.HM_10_SERVICE_G4];
		private static const uuids_G5_Service:Vector.<String> = new <String>["F8083532-849E-531C-C594-30F1F86A4EA5"];
		private static const uuids_G5_Advertisement:Vector.<String> = new <String>["0000FEBC-0000-1000-8000-00805F9B34FB"];
		private static const uuids_G4_Characteristics:Vector.<String> = new <String>[HM10Attributes.HM_RX_TX_G4];
		private static const uuids_G5_Characteristics:Vector.<String> = new <String>[HM10Attributes.G5_Authentication_Characteristic_UUID, HM10Attributes.G5_Communication_Characteristic_UUID, HM10Attributes.G5_Control_Characteristic_UUID];
		private static var connectionAttemptTimeStamp:Number;
		private static const maxTimeBetweenConnectAttemptAndConnectSuccess:Number = 3;
		private static var waitingForPeripheralCharacteristicsDiscovered:Boolean = false;
		private static var waitingForServicesDiscovered:Boolean = false;
		
		private static var authRequest:AuthRequestTxMessage = null;
		private static var authStatus:AuthStatusRxMessage = null;
		private static var discoveryTimeStamp:Number;
		
		public static const BATTERY_READ_PERIOD_MS:Number = 1000 * 60 * 60 * 12; // how often to poll battery data (12 hours)
		
		public static var isDexcomG5:Boolean;
		private static var timeStampOfLastDeviceDiscovery:Number = 0;
		private static var scanTimer:Timer;
		
		private static function set activeBluetoothPeripheral(value:Peripheral):void
		{
			if (value == _activeBluetoothPeripheral)
				return;
			
			_activeBluetoothPeripheral = value;
			
			if (_activeBluetoothPeripheral != null) {
				_activeBluetoothPeripheral.addEventListener(PeripheralEvent.DISCOVER_SERVICES, peripheral_discoverServicesHandler );
				_activeBluetoothPeripheral.addEventListener(PeripheralEvent.DISCOVER_CHARACTERISTICS, peripheral_discoverCharacteristicsHandler );
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.UPDATE, peripheral_characteristic_updatedHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.UPDATE_ERROR, peripheral_characteristic_errorHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.SUBSCRIBE, peripheral_characteristic_subscribeHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.SUBSCRIBE_ERROR, peripheral_characteristic_subscribeErrorHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.UNSUBSCRIBE, peripheral_characteristic_unsubscribeHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.WRITE_SUCCESS, peripheral_characteristic_writeHandler);
				_activeBluetoothPeripheral.addEventListener(CharacteristicEvent.WRITE_ERROR, peripheral_characteristic_writeErrorHandler);
			}
		}
		
		private static function get activeBluetoothPeripheral():Peripheral {
			return _activeBluetoothPeripheral;
		}
		
		private static var _G4characteristic:Characteristic;
		
		private static function get G4characteristic():Characteristic
		{
			return _G4characteristic;
		}
		
		private static function set G4characteristic(value:Characteristic):void
		{
			_G4characteristic = value;
		}
		
		private static var _G5AuthenticationCharacteristic:Characteristic;
		
		private static function get G5AuthenticationCharacteristic():Characteristic
		{
			return _G5AuthenticationCharacteristic;
		}
		
		private static function set G5AuthenticationCharacteristic(value:Characteristic):void
		{
			_G5AuthenticationCharacteristic = value;
		}
		
		private static var _G5CommunicationCharacteristic:Characteristic;
		
		private static function get G5CommunicationCharacteristic():Characteristic
		{
			return _G5CommunicationCharacteristic;
		}
		
		private static function set G5CommunicationCharacteristic(value:Characteristic):void
		{
			_G5CommunicationCharacteristic = value;
		}
		
		private static var _G5ControlCharacteristic:Characteristic;
		
		private static function get G5ControlCharacteristic():Characteristic
		{
			return _G5ControlCharacteristic;
		}
		
		private static function set G5ControlCharacteristic(value:Characteristic):void
		{
			_G5ControlCharacteristic = value;
		}
		
		public function BluetoothService()
		{
			if (_instance != null) {
				throw new Error("BluetoothService class constructor can not be used");	
			}
		}
		
		/**
		 * start all bluetooth related activity : scanning, connecting, start listening ...<br>
		 * Also intializes BlueToothDevice with values retrieved from Database. 
		 */
		public static function init():void {
			if (!initialStart)
				return;
			else
				initialStart = false;
			
			CommonSettings.instance.addEventListener(SettingsServiceEvent.SETTING_CHANGED, settingChanged);
			
			isDexcomG5 = (CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_PERIPHERAL_TYPE) == "G5");
			
			BluetoothLE.init(DistriqtKey.distriqtKey);
			if (BluetoothLE.isSupported) {
				myTrace("passing bluetoothservice.issupported");
				myTrace("authorisation status = " + BluetoothLE.service.authorisationStatus());
				switch (BluetoothLE.service.authorisationStatus()) {
					case AuthorisationStatus.SHOULD_EXPLAIN:
						BluetoothLE.service.requestAuthorisation();
						break;
					case AuthorisationStatus.DENIED:
					case AuthorisationStatus.RESTRICTED:
					case AuthorisationStatus.UNKNOWN:
						break;
					
					case AuthorisationStatus.NOT_DETERMINED:
					case AuthorisationStatus.AUTHORISED:				
						BluetoothLE.service.centralManager.addEventListener(PeripheralEvent.DISCOVERED, central_peripheralDiscoveredHandler);
						BluetoothLE.service.centralManager.addEventListener(PeripheralEvent.CONNECT, central_peripheralConnectHandler );
						BluetoothLE.service.centralManager.addEventListener(PeripheralEvent.CONNECT_FAIL, central_peripheralDisconnectHandler );
						BluetoothLE.service.centralManager.addEventListener(PeripheralEvent.DISCONNECT, central_peripheralDisconnectHandler );
						BluetoothLE.service.addEventListener(BluetoothLEEvent.STATE_CHANGED, bluetoothStateChangedHandler);
						
						var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_SERVICE_INITIATED);
						_instance.dispatchEvent(blueToothServiceEvent);
						
						switch (BluetoothLE.service.centralManager.state)
						{
							case BluetoothLEState.STATE_ON:	
								// We can use the Bluetooth LE functions
								bluetoothStatusIsOn();
								myTrace("bluetooth is switched on")
								break;
							case BluetoothLEState.STATE_OFF:
								myTrace("bluetooth is switched off")
								break;
							case BluetoothLEState.STATE_RESETTING:	
								break;
							case BluetoothLEState.STATE_UNAUTHORISED:
								break;
							case BluetoothLEState.STATE_UNSUPPORTED:
								break;
							case BluetoothLEState.STATE_UNKNOWN:
								break;
						}
				}
				
			} else {
				myTrace("Unfortunately your Device does not support Bluetooth Low Energy");
			}
		}
		
		private static function settingChanged(event:SettingsServiceEvent):void {
			if (event.data == CommonSettings.COMMON_SETTING_PERIPHERAL_TYPE) {
				if (CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_PERIPHERAL_TYPE) == "G5") {
					isDexcomG5 = true;					
				} else {
					isDexcomG5 = false;
				}
			} else if (event.data == CommonSettings.COMMON_SETTING_TRANSMITTER_ID) {
				if (isDexcomG5) {
					myTrace("in settingChanged, event.data = COMMON_SETTING_TRANSMITTER_ID, calling forgetbluetoothdevice");
					BlueToothDevice.forgetBlueToothDevice();
				}
			}
		}
		
		private static function treatNewBlueToothStatus(newStatus:String):void {
			switch (BluetoothLE.service.centralManager.state)
			{
				case BluetoothLEState.STATE_ON:	
					myTrace("bluetooth is switched on")
					// We can use the Bluetooth LE functions
					bluetoothStatusIsOn();
					break;
				case BluetoothLEState.STATE_OFF:
					myTrace("bluetooth is switched off")
					break;//does the device automatically change to connected ? 
				case BluetoothLEState.STATE_RESETTING:	
					break;
				case BluetoothLEState.STATE_UNAUTHORISED:	
					break;
				case BluetoothLEState.STATE_UNSUPPORTED:	
					break;
				case BluetoothLEState.STATE_UNKNOWN:
					break;
			}
		}
		
		private static function bluetoothStateChangedHandler(event:BluetoothLEEvent):void
		{
			treatNewBlueToothStatus(BluetoothLE.service.centralManager.state);					
		}
		
		private static function bluetoothStatusIsOn():void {
			if (activeBluetoothPeripheral != null && !(isDexcomG5)) {//do we ever pass here, activebluetoothperipheral is set to null after disconnect
				awaitingConnect = true;
				connectionAttemptTimeStamp = (new Date()).valueOf();
				BluetoothLE.service.centralManager.connect(activeBluetoothPeripheral);
				myTrace("Trying to connect to known device.");
			} else if (BlueToothDevice.known() || (isDexcomG5)) {
				myTrace("call startScanning");
				startScanning();
			} else {
				myTrace("in bluetootbluetoothStatusIsOn but not restarting scan because it's not a G5 or peripheral = null or no device known");
			}
		}
		
		public static function startScanning(initialG4Scan:Boolean = false):void {
			if (!BluetoothLE.service.centralManager.isScanning) {
				if (!BluetoothLE.service.centralManager.scanForPeripherals(isDexcomG5 ? uuids_G5_Advertisement:uuids_G4_Service))
				{
					myTrace("failed to start scanning for peripherals");
					return;
				} else {
					myTrace("started scanning for peripherals");
					if (initialG4Scan) {
						myTrace("it's a G4 scan, starting scanTimer");
						scanTimer = new Timer(MAX_SCAN_TIME_IN_SECONDS * 1000, 1);
						scanTimer.addEventListener(TimerEvent.TIMER, stopScanning);
						scanTimer.start();
					}
				}
			} else {
				myTrace("in startscanning but already scanning");
			}
		}
		
		private static function stopScanning(event:Event):void {
			myTrace("in stopScanning");
			if (BluetoothLE.service.centralManager.isScanning) {
				myTrace("in stopScanning, is scanning, call stopScan");
				BluetoothLE.service.centralManager.stopScan();
				_instance.dispatchEvent(new BlueToothServiceEvent(BlueToothServiceEvent.STOPPED_SCANNING));
			}
		}
		
		private static function central_peripheralDiscoveredHandler(event:PeripheralEvent):void {//LimiTix
			myTrace("in central_peripheralDiscoveredHandler, stop scanning");
			BluetoothLE.service.centralManager.stopScan();

			discoveryTimeStamp = (new Date()).valueOf();
			if (awaitingConnect && !(isDexcomG5)) {
				myTrace("passing in central_peripheralDiscoveredHandler but already awaiting connect, ignoring this one. peripheral name = " + event.peripheral.name);
				myTrace("restart scan");
				startRescan(null);
				return;
			} else {
				myTrace("passing in central_peripheralDiscoveredHandler. Peripheral name = " + event.peripheral.name);
			}
			
			if (isDexcomG5) {
				if ((new Date()).valueOf() - timeStampOfLastDeviceDiscovery < 60 * 1000) {
					myTrace("G5 but last reading was less than 1 minute ago, ignoring this peripheral discovery");
					myTrace("restart scan");
					startRescan(null);
					return;
				}
			}
			
			// event.peripheral will contain a Peripheral object with information about the Peripheral
			var expectedG5_name:String;
			if (isDexcomG5) {
				expectedG5_name = "DEXCOM" + CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_TRANSMITTER_ID).substring(4,6);
				myTrace("expected g5 device name = " + expectedG5_name);
			}
			if (
				(!(isDexcomG5) && 
					(
						(event.peripheral.name as String).toUpperCase().indexOf("DRIP") > -1 
						|| (event.peripheral.name as String).toUpperCase().indexOf("BRIDGE") > -1 
						|| (event.peripheral.name as String).toUpperCase().indexOf("LIMITIX") > -1
						|| (event.peripheral.name as String).toUpperCase().indexOf("LIMITTER") > -1
					)
				) 
				||
				(isDexcomG5 && 
					(
						(event.peripheral.name as String).toUpperCase().indexOf(expectedG5_name) > -1
					)
				)
			) {
				myTrace("Found peripheral with name" + " = " + event.peripheral.name);
				timeStampOfLastDeviceDiscovery = (new Date()).valueOf();
				
				if (BlueToothDevice.address != "") {
					if (BlueToothDevice.address != event.peripheral.uuid) {
						//a bluetooth device address is already stored, but it's not the one for which peripheraldiscoveredhandler is called
						//so we ignore it
						myTrace("UUID of found peripheral does not match with name of the UUID stored in the database - will ignore this xdrip/xbridge/LimiTTer/Dexcom.");
						//BluetoothLE.service.centralManager.stopScan();
						return;
					}
				} else {
					//we store also this device, as of now, all future connect attempts will be only to this one, until the user choses "forget device"
					BlueToothDevice.address = event.peripheral.uuid;
					BlueToothDevice.name = event.peripheral.name;
					myTrace("Device details will be stored in database. Future attempts will only use this device to connect to.");
				}
				
				awaitingConnect = true;
				connectionAttemptTimeStamp = (new Date()).valueOf();
				BluetoothLE.service.centralManager.connect(event.peripheral);
				
			} else {
				myTrace("doesn't seem to be a device we are interested in, either it's not an xdrip/bridge, .. or it's a G5 but not with the right name - restart scan");
				startRescan(null);
			}
		}
		
		private static function central_peripheralConnectHandler(event:PeripheralEvent):void {
			if (!awaitingConnect) {
				myTrace("in central_peripheralConnectHandler but awaitingConnect = false, will disconnect");
				//activeBluetoothPeripheral = null;
				BluetoothLE.service.centralManager.disconnect(event.peripheral);
				return;
			} 
			
			awaitingConnect = false;
			if (!isDexcomG5) {
				if ((new Date()).valueOf() - connectionAttemptTimeStamp > maxTimeBetweenConnectAttemptAndConnectSuccess * 1000) { //not waiting more than 3 seconds between device discovery and connection success
					myTrace("passing in central_peripheralConnectHandler but time between connect attempt and connect success is more than " + maxTimeBetweenConnectAttemptAndConnectSuccess + " seconds. Will disconnect");
					BluetoothLE.service.centralManager.disconnect(event.peripheral);
					return;
				} 
			}
			
			myTrace("connected to peripheral");
			if (activeBluetoothPeripheral == null)
				activeBluetoothPeripheral = event.peripheral;
			
			discoverServices();
		}
		
		private static function discoverServices(event:Event = null):void {
			waitingForServicesDiscovered = false;
			if (activeBluetoothPeripheral == null)//rare case, user might have done forget xdrip while waiting for rettempt
				return;
			
			if (discoverServiceOrCharacteristicTimer != null) {
				discoverServiceOrCharacteristicTimer.stop();
				discoverServiceOrCharacteristicTimer = null;
			}
			
			if (amountOfDiscoverServicesOrCharacteristicsAttempt < MAX_RETRY_DISCOVER_SERVICES_OR_CHARACTERISTICS) {
				amountOfDiscoverServicesOrCharacteristicsAttempt++;
				myTrace("discoverservices attempt " + amountOfDiscoverServicesOrCharacteristicsAttempt);
				
				waitingForServicesDiscovered = true;
				activeBluetoothPeripheral.discoverServices(isDexcomG5 ? uuids_G5_Service:uuids_G4_Service);
				discoverServiceOrCharacteristicTimer = new Timer(DISCOVER_SERVICES_OR_CHARACTERISTICS_RETRY_TIME_IN_SECONDS * 1000, 1);
				discoverServiceOrCharacteristicTimer.addEventListener(TimerEvent.TIMER, discoverServices);
				discoverServiceOrCharacteristicTimer.start();
			} else {
				myTrace("Maximum amount of attempts for discover bluetooth services reached.")
				amountOfDiscoverServicesOrCharacteristicsAttempt = 0;
				
				//i just happens that retrying doesn't help anymore
				//so disconnecting and rescanning seems the only solution ?
				
				//disconnect will cause central_peripheralDisconnectHandler to be called (although not sure because setting activeBluetoothPeripheral to null, i would expect that removes also the eventlisteners
				//central_peripheralDisconnectHandler will see that activeBluetoothPeripheral == null and so 
				var temp:Peripheral = activeBluetoothPeripheral;
				activeBluetoothPeripheral = null;
				BluetoothLE.service.centralManager.disconnect(temp);
				
				myTrace("will_re_scan_for_device");
				
				if ((BluetoothLE.service.centralManager.state == BluetoothLEState.STATE_ON)) {
					bluetoothStatusIsOn();
				}
			}
		}
		
		private static function central_peripheralDisconnectHandler(event:Event = null):void {
			myTrace('Disconnected from device or attempt to reconnect failed.');
			awaitingConnect = false;
			forgetBlueToothDevice();
			startRescan(null);
		}
		
		private static function tryReconnect(event:Event = null):void {
			if ((BluetoothLE.service.centralManager.state == BluetoothLEState.STATE_ON)) {
				bluetoothStatusIsOn();
			} else {
				//no need to further retry, a reconnect will be done as soon as bluetooth is switched on
			}
		}
		
		private static function peripheral_discoverServicesHandler(event:PeripheralEvent):void {
			if (!waitingForServicesDiscovered && !(isDexcomG5)) {
				myTrace("in peripheral_discoverServicesHandler but not waitingForServicesDiscovered and not dexcom g5, ignoring");
				return;
			} else if (waitingForServicesDiscovered && !(isDexcomG5)) {
				myTrace("in peripheral_discoverServicesHandler and waitingForServicesDiscovered and not dexcom g5");
			} else 
				myTrace("in peripheral_discoverServicesHandler and dexcom g5");
			waitingForServicesDiscovered = false;
			
			if (discoverServiceOrCharacteristicTimer != null) {
				discoverServiceOrCharacteristicTimer.stop();
				discoverServiceOrCharacteristicTimer = null;
			}
			myTrace("Bluetooth peripheral services discovered.");
			amountOfDiscoverServicesOrCharacteristicsAttempt = 0;
			
			if (event.peripheral.services.length > 0)
			{
				discoverCharacteristics();
			}
		}
		
		private static function discoverCharacteristics(event:Event = null):void {
			if (activeBluetoothPeripheral == null)//rare case, user might have done forget xdrip while waiting to reattempt
				return;
			
			if (discoverServiceOrCharacteristicTimer != null) {
				discoverServiceOrCharacteristicTimer.stop();
				discoverServiceOrCharacteristicTimer = null;
			}
			
			if (amountOfDiscoverServicesOrCharacteristicsAttempt < MAX_RETRY_DISCOVER_SERVICES_OR_CHARACTERISTICS
				&&
				activeBluetoothPeripheral.services.length > 0) {
				amountOfDiscoverServicesOrCharacteristicsAttempt++;
				var message:String = 'launching_discovercharacteristics_attempt_amount' + " " + amountOfDiscoverServicesOrCharacteristicsAttempt;
				myTrace(message);
				
				//find the index of the service that has uuid = the one used by xdrip/xbridge or Dexcom
				var index:int;
				if (isDexcomG5) {
					for each (var o:Object in activeBluetoothPeripheral.services) {
						if (HM10Attributes.HM_10_SERVICE_G5.indexOf((o.uuid as String).toUpperCase()) > -1) {
							break;
						}
						index++;
					}
				} else {
					for each (var o:Object in activeBluetoothPeripheral.services) {
						if (HM10Attributes.HM_10_SERVICE_G4.indexOf(o.uuid as String) > -1) {
							break;
						}
						index++;
					}
				}
				
				waitingForPeripheralCharacteristicsDiscovered = true;
				activeBluetoothPeripheral.discoverCharacteristics(activeBluetoothPeripheral.services[index], isDexcomG5 ? uuids_G5_Characteristics:uuids_G4_Characteristics);
				discoverServiceOrCharacteristicTimer = new Timer(DISCOVER_SERVICES_OR_CHARACTERISTICS_RETRY_TIME_IN_SECONDS * 1000, 1);
				discoverServiceOrCharacteristicTimer.addEventListener(TimerEvent.TIMER, discoverCharacteristics);
				discoverServiceOrCharacteristicTimer.start();
			} else {
				if (amountOfDiscoverServicesOrCharacteristicsAttempt == MAX_RETRY_DISCOVER_SERVICES_OR_CHARACTERISTICS) {
					myTrace("amountOfDiscoverServicesOrCharacteristicsAttempt == MAX_RETRY_DISCOVER_SERVICES_OR_CHARACTERISTICS"); 
					myTrace("max_amount_of_discover_characteristics_attempt_reached");
				}
				if (activeBluetoothPeripheral.services.length == 0 && !(isDexcomG5)) {
					myTrace("activeBluetoothPeripheral.services.length == 0"); 
				} else if (activeBluetoothPeripheral.services.length == 0 && (isDexcomG5)) {
					myTrace("activeBluetoothPeripheral.services.length == 0 but it's a dexcomg5, not trying to reconnect");
				}
				tryReconnect();
			}
		}
		
		private static function peripheral_discoverCharacteristicsHandler(event:PeripheralEvent):void {
			myTrace("in peripheral_discoverCharacteristicsHandler");
			if (!waitingForPeripheralCharacteristicsDiscovered) {
				myTrace("in peripheral_discoverCharacteristicsHandler but not waitingForPeripheralCharacteristicsDiscovered");
				return;
			}
			waitingForPeripheralCharacteristicsDiscovered = false;
			if (discoverServiceOrCharacteristicTimer != null) {
				discoverServiceOrCharacteristicTimer.stop();
				discoverServiceOrCharacteristicTimer = null;
			}
			myTrace("Bluetooth peripheral characteristics discovered");
			amountOfDiscoverServicesOrCharacteristicsAttempt = 0;
			
			//find the index of the service that has uuid = the one used by xdrip/xbridge
			var servicesIndex:int = 0;
			var G4CharacteristicsIndex:int = 0;
			var G5AuthenticationCharacteristicsIndex:int = 0;
			var G5CommunicationCharacteristicsIndex:int = 0;
			var G5ControlCharacteristicsIndex:int = 0;
			var o:Object;
			if (isDexcomG5) {
				for each (o in activeBluetoothPeripheral.services) {
					if (HM10Attributes.HM_10_SERVICE_G5.indexOf((o.uuid as String).toUpperCase()) > -1) {
						break;
					}
					servicesIndex++;
				}
				for each (o in activeBluetoothPeripheral.services[servicesIndex].characteristics) {
					if (HM10Attributes.G5_Authentication_Characteristic_UUID.indexOf((o.uuid as String).toUpperCase()) > -1) {
						break;
					}
					G5AuthenticationCharacteristicsIndex++;
				}
				for each (o in activeBluetoothPeripheral.services[servicesIndex].characteristics) {
					if (HM10Attributes.G5_Communication_Characteristic_UUID.indexOf((o.uuid as String).toUpperCase()) > -1) {
						break;
					}
					G5CommunicationCharacteristicsIndex++;
				}
				for each (o in activeBluetoothPeripheral.services[servicesIndex].characteristics) {
					if (HM10Attributes.G5_Control_Characteristic_UUID.indexOf((o.uuid as String).toUpperCase()) > -1) {
						break;
					}
					G5ControlCharacteristicsIndex++;
				}
				G5AuthenticationCharacteristic = event.peripheral.services[servicesIndex].characteristics[G5AuthenticationCharacteristicsIndex];
				G5CommunicationCharacteristic = event.peripheral.services[servicesIndex].characteristics[G5CommunicationCharacteristicsIndex];
				G5ControlCharacteristic = event.peripheral.services[servicesIndex].characteristics[G5ControlCharacteristicsIndex];
				myTrace("subscribing to G5AuthenticationCharacteristic");
				
				if (!activeBluetoothPeripheral.subscribeToCharacteristic(G5AuthenticationCharacteristic))
				{
					myTrace("Subscribe to characteristic failed due to invalid adapter state.");
				}
			} else {
				for each (o in activeBluetoothPeripheral.services) {
					if (HM10Attributes.HM_10_SERVICE_G4.indexOf(o.uuid as String) > -1) {
						break;
					}
					servicesIndex++;
				}
				for each (o in activeBluetoothPeripheral.services[servicesIndex].characteristics) {
					if (HM10Attributes.HM_RX_TX_G4.indexOf(o.uuid as String) > -1) {
						break;
					}
					G4CharacteristicsIndex++;
				}
				G4characteristic = event.peripheral.services[servicesIndex].characteristics[G4CharacteristicsIndex];
				if (!activeBluetoothPeripheral.subscribeToCharacteristic(G4characteristic))
				{
					myTrace("Subscribe to characteristic failed due to invalid adapter state.");
				}
			}
		}
		
		/**
		 * simply acknowledges receipt of a message, needed for xbridge so that it goes to sleep<br>
		 * Can also be the transmitter id. 
		 */
		public static function ackCharacteristicUpdate(value:ByteArray):void {
			if (!activeBluetoothPeripheral.writeValueForCharacteristic(G4characteristic, value)) {
				myTrace("ackCharacteristicUpdate writeValueForCharacteristic failed");
			}
		}
		
		private static function peripheral_characteristic_updatedHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_updatedHandler characteristic uuid = " + HM10Attributes.getCharacteristicName(event.characteristic.uuid) +
				" with byte 0 = " + event.characteristic.value[0] + " decimal.");
			
			var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.CHARACTERISTIC_UPDATE);
			_instance.dispatchEvent(blueToothServiceEvent);
			
			//now start reading the values
			var value:ByteArray = event.characteristic.value;
			var packetlength:int = value.readUnsignedByte();
			if (packetlength == 0) {
				myTrace("data packet received from transmitter with length 0");
			} else {
				value.position = 0;
				value.endian = Endian.LITTLE_ENDIAN;
				myTrace("data packet received from transmitter : " + Utilities.UniqueId.bytesToHex(value));
				value.position = 0;
				if (isDexcomG5) {
					processG5TransmitterData(value, event.characteristic);
				} else {
					processG4TransmitterData(value);
				}
			}
		}
		
		private static function peripheral_characteristic_writeHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_writeHandler" + HM10Attributes.getCharacteristicName(event.characteristic.uuid));
			if (isDexcomG5) {
			} else {
				_instance.dispatchEvent(new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_DEVICE_CONNECTION_COMPLETED));
			}
		}
		
		private static function peripheral_characteristic_writeErrorHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_writeErrorHandler"  + HM10Attributes.getCharacteristicName(event.characteristic.uuid));
		}
		
		private static function peripheral_characteristic_errorHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_errorHandler"  + HM10Attributes.getCharacteristicName(event.characteristic.uuid));
		}
		
		private static function peripheral_characteristic_subscribeHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_subscribeHandler success: " + HM10Attributes.getCharacteristicName(event.characteristic.uuid));
			if (isDexcomG5) {
				if (event.characteristic.uuid.toUpperCase() == HM10Attributes.G5_Control_Characteristic_UUID.toUpperCase()) {
					getSensorData();
				} else {
					fullAuthenticateG5();
				}
			} else {
				_instance.dispatchEvent(new BlueToothServiceEvent(BlueToothServiceEvent.BLUETOOTH_DEVICE_CONNECTION_COMPLETED));
			}
		}
		
		private static function peripheral_characteristic_subscribeErrorHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_subscribeErrorHandler: " + HM10Attributes.getCharacteristicName(event.characteristic.uuid));
			myTrace("event.error = " + event.error);
			myTrace("event.errorcode  = " + event.errorCode);
		}
		
		private static function peripheral_characteristic_unsubscribeHandler(event:CharacteristicEvent):void {
			myTrace("peripheral_characteristic_unsubscribeHandler: " + event.characteristic.uuid);	
		}
		
		/**
		 * Disconnects the active bluetooth peripheral if any and sets it to null(otherwise returns without doing anything)<br>
		 */
		public static function forgetBlueToothDevice():void {
			if (activeBluetoothPeripheral == null)
				return;
			
			BluetoothLE.service.centralManager.disconnect(activeBluetoothPeripheral);
			activeBluetoothPeripheral = null;
			
			myTrace("bluetooth device forgotten");
		}
		
		/**
		 * encode transmitter id as explained in xBridge2.pdf 
		 */
		public static function encodeTxID(TxID:String):Number {
			var returnValue:Number = 0;
			var tmpSrc:String = TxID.toUpperCase();
			returnValue |= getSrcValue(tmpSrc.charAt(0)) << 20;
			returnValue |= getSrcValue(tmpSrc.charAt(1)) << 15;
			returnValue |= getSrcValue(tmpSrc.charAt(2)) << 10;
			returnValue |= getSrcValue(tmpSrc.charAt(3)) << 5;
			returnValue |= getSrcValue(tmpSrc.charAt(4));
			return returnValue;
		}
		
		private static function decodeTxID(TxID:Number):String {
			var returnValue:String = "";
			returnValue += srcNameTable[(TxID >> 20) & 0x1F];
			returnValue += srcNameTable[(TxID >> 15) & 0x1F];
			returnValue += srcNameTable[(TxID >> 10) & 0x1F];
			returnValue += srcNameTable[(TxID >> 5) & 0x1F];
			returnValue += srcNameTable[(TxID >> 0) & 0x1F];
			return returnValue;
		}
		
		private static function getSrcValue(ch:String):int {
			var i:int = 0;
			for (i = 0; i < srcNameTable.length; i++) {
				if (srcNameTable[i] == ch) break;
			}
			return i;
		}
		
		private static function processG5TransmitterData(buffer:ByteArray, characteristic:Characteristic):void {
			buffer.endian = Endian.LITTLE_ENDIAN;
			var code:int = buffer.readByte();
			switch (code) {
				case 5:
					authStatus = new AuthStatusRxMessage(buffer);
					myTrace("AuthStatusRxMessage created = " + UniqueId.byteArrayToString(authStatus.byteSequence));
					if (!authStatus.bonded) {
						myTrace("not bonded, dispatching DEVICE_NOT_PAIRED event");
						var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.DEVICE_NOT_PAIRED);
						_instance.dispatchEvent(blueToothServiceEvent);
					}
					myTrace("Subscribing to G5ControlCharacteristic");
					if (!activeBluetoothPeripheral.subscribeToCharacteristic(G5ControlCharacteristic))
					{
						myTrace("Subscribe to characteristic failed due to invalid adapter state.");
					}
					break;
				case 3:
					buffer.position = 0;
					var authChallenge:AuthChallengeRxMessage = new AuthChallengeRxMessage(buffer);
					if (authRequest == null) {
						authRequest = new AuthRequestTxMessage(getTokenSize());
					}
					var key:ByteArray = cryptKey();
					var challengeHash:ByteArray = calculateHash(authChallenge.challenge);
					if (challengeHash != null) {
						var authChallengeTx:AuthChallengeTxMessage = new AuthChallengeTxMessage(challengeHash);
						if (!activeBluetoothPeripheral.writeValueForCharacteristic(characteristic, authChallengeTx.byteSequence)) {
							myTrace("processG5TransmitterData case 3 writeValueForCharacteristic failed");
						}
					} else {
						myTrace("challengehash == null");
					}
					break;
				case 47:
					var sensorRx:SensorRxMessage = new SensorRxMessage(buffer);
					var sensor_battery_level:Number = 0;
					if (sensorRx.transmitterStatus.toString() == TransmitterStatus.BRICKED) {
						sensor_battery_level = 206; //will give message "EMPTY"
					} else if (sensorRx.transmitterStatus.toString() == TransmitterStatus.LOW) {
						sensor_battery_level = 209; //will give message "LOW"
					} else {
						sensor_battery_level = 216; //no message, just system status "OK"
					}
					
					if ((new Date()).valueOf() - new Number(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_G5_BATTERY_FROM_MARKER)) > BluetoothService.BATTERY_READ_PERIOD_MS) {
						doBatteryInfoRequestMessage(characteristic);
					} else {
						doDisconnectMessageG5(characteristic);
					}
					
					var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.TRANSMITTER_DATA);
					blueToothServiceEvent.data = new TransmitterDataG5Packet(sensorRx.unfiltered, sensorRx.filtered, sensor_battery_level, sensorRx.timestamp, sensorRx.transmitterStatus);
					_instance.dispatchEvent(blueToothServiceEvent);
					break;
				case 35:
					buffer.position = 0;
					if (!setStoredBatteryBytesG5(buffer)) {
						myTrace("Could not save out battery data!");
					}
					doDisconnectMessageG5(characteristic);
					break;
				case 75:
					doDisconnectMessageG5(characteristic);
					break;
				default:
					myTrace("processG5TransmitterData unknown code received : " + code);
					break;
			}
		}
		
		public static function setStoredBatteryBytesG5(data:ByteArray):Boolean {
			myTrace("Store: BatteryRX dbg: " + UniqueId.bytesToHex((data)));
			if (data.length < 10) {
				myTrace("Store: BatteryRX dbg, data.length < 10, no further processing");
				return false;
			}
			var batteryInfoRxMessage:BatteryInfoRxMessage = new BatteryInfoRxMessage(data);
			myTrace("Saving battery data: " + batteryInfoRxMessage.toString());
			CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_G5_BATTERY_MARKER, UniqueId.bytesToHex(data));
			CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_G5_RESIST, new Number(batteryInfoRxMessage.resist).toString());
			CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_G5_RUNTIME, new Number(batteryInfoRxMessage.runtime).toString());
			CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_G5_STATUS, new Number(batteryInfoRxMessage.status).toString());
			CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_G5_TEMPERATURE, new Number(batteryInfoRxMessage.temperature).toString());
			CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_G5_VOLTAGEA, new Number(batteryInfoRxMessage.voltagea).toString());
			CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_G5_VOLTAGEB, new Number(batteryInfoRxMessage.voltageb).toString());
			return true;
		}
		
		private static function doDisconnectMessageG5(characteristic:Characteristic):void {
			myTrace("in doDisconnectMessageG5");
			if (activeBluetoothPeripheral != null) {
				if (!BluetoothLE.service.centralManager.disconnect(activeBluetoothPeripheral)) {
					myTrace("doDisconnectMessageG5 failed");
				}
			}
			forgetBlueToothDevice();
			myTrace("doDisconnectMessageG5 finished");
		}
		
		private static function doBatteryInfoRequestMessage(characteristic:Characteristic):void {
			myTrace("doBatteryInfoRequestMessage");
			var batteryInfoTxMessage:BatteryInfoTxMessage =  new BatteryInfoTxMessage();
			if (!activeBluetoothPeripheral.writeValueForCharacteristic(characteristic, batteryInfoTxMessage.byteSequence)) {
				myTrace("doBatteryInfoRequestMessage writeValueForCharacteristic failed");
			}
		}
		
		public static function calculateHash(data:ByteArray):ByteArray {
			if (data.length != 8) {
				myTrace("Data length should be exactly 8.");
				return null;
			}
			var key:ByteArray = cryptKey();
			if (key == null)
				return null;
			var doubleData:ByteArray = new ByteArray();
			doubleData.writeBytes(data);
			doubleData.writeBytes(data);
			var aesBytes:ByteArray = BackgroundFetch.AESEncryptWithKey(key, doubleData);
			var returnValue:ByteArray = new ByteArray();
			returnValue.writeBytes(aesBytes, 0, 8);
			return returnValue;
		}
		
		public static function cryptKey():ByteArray {
			var transmitterId:String = CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_TRANSMITTER_ID);
			var returnValue:ByteArray =  new ByteArray();
			returnValue.writeMultiByte("00" + transmitterId + "00" + transmitterId,"iso-8859-1");
			return returnValue;
		}
		
		private static function processG4TransmitterData(buffer:ByteArray):void {
			buffer.endian = Endian.LITTLE_ENDIAN;
			var packetLength:int = buffer.readUnsignedByte();
			var packetType:int = buffer.readUnsignedByte();//0 = data packet, 1 =  TXID packet, 0xF1 (241 if read as unsigned int) = Beacon packet
			var txID:Number;
			var xBridgeProtocolLevel:Number
			switch (packetType) {
				case 0:
					//data packet
					var rawData:Number = buffer.readInt();
					var filteredData:Number = buffer.readInt();
					var transmitterBatteryVoltage:Number = buffer.readUnsignedByte();
					
					//following only if the name of the device contains "bridge", if it' doesnt contain bridge, then it's an xdrip (old) and doesn't have those bytes' +
					//or if packetlenth == 17, why ? because it could be a drip with xbridge software but still with a name xdrip, because it was originally an xdrip that was later on overwritten by the xbridge software, in that case the name will still by xdrip and not xbridge
					if (BlueToothDevice.isXBridge() || packetLength == 17) {
						var bridgeBatteryPercentage:Number = buffer.readUnsignedByte();
						txID = buffer.readInt();
						xBridgeProtocolLevel = buffer.readUnsignedByte();
						
						var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.TRANSMITTER_DATA);
						blueToothServiceEvent.data = new TransmitterDataXBridgeDataPacket(rawData, filteredData, transmitterBatteryVoltage, bridgeBatteryPercentage, decodeTxID(txID));
						_instance.dispatchEvent(blueToothServiceEvent);
					} else {
						var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.TRANSMITTER_DATA);
						blueToothServiceEvent.data = new TransmitterDataXdripDataPacket(rawData, filteredData, transmitterBatteryVoltage);
						_instance.dispatchEvent(blueToothServiceEvent);
					}
					
					break;
				case 1://will actually never happen, this is a packet type for the other direction , ie from App to xbridge
					//TXID packet
					txID = buffer.readInt();
					break;
				case 241:
					//Beacon packet
					txID = buffer.readInt();
					
					var blueToothServiceEvent:BlueToothServiceEvent = new BlueToothServiceEvent(BlueToothServiceEvent.TRANSMITTER_DATA);
					blueToothServiceEvent.data = new TransmitterDataXBridgeBeaconPacket(decodeTxID(txID));
					_instance.dispatchEvent(blueToothServiceEvent);
					
					xBridgeProtocolLevel = buffer.readUnsignedByte();//not needed for the moment
					break;
			}
		}
		
		private static function myTrace(log:String):void {
			Trace.myTrace("BluetoothService.as", log);
		}
		
		/**
		 * returns true if activeBluetoothPeripheral != null
		 */
		public static function bluetoothPeripheralActive():Boolean {
			return activeBluetoothPeripheral != null;
		}
		
		public static function fullAuthenticateG5():void {
			myTrace("in fullAuthenticateG5");
			if (G5AuthenticationCharacteristic != null) {
				sendAuthRequestTxMessage(G5AuthenticationCharacteristic);
			} else {
				myTrace("fullAuthenticate: authCharacteristic is NULL!");
			}
		}
		
		private static function sendAuthRequestTxMessage(characteristic:Characteristic):void {
			authRequest = new AuthRequestTxMessage(getTokenSize());
			
			if (!activeBluetoothPeripheral.writeValueForCharacteristic(characteristic, authRequest.byteSequence)) {
				myTrace("sendAuthRequestTxMessage writeValueForCharacteristic failed");
			}
		}
		
		private static function getTokenSize():Number {
			return 8;
		}
		
		public static function getSensorData():void {
			myTrace("getSensorData");
			var sensorTx:SensorTxMessage = new SensorTxMessage();
			if (!activeBluetoothPeripheral.writeValueForCharacteristic(G5ControlCharacteristic, sensorTx.byteSequence)) {
				myTrace("getSensorData writeValueForCharacteristic G5CommunicationCharacteristic failed");
			}
		}
		
		/**
		 * to be called when performfetch is received, this will actually start the rescan 
		 */
		public static function startRescan(event:Event):void {
			if (!(BluetoothLE.service.centralManager.state == BluetoothLEState.STATE_ON)) {
				myTrace("In rescanAtPerformFetch but bluetooth is not on");
				return;
			}
			
			if (HomeView.peripheralConnected) {
				myTrace("In startRescan but connected so returning");
				return;
			}
			
			if (!BluetoothLE.service.centralManager.isScanning) {
				myTrace("in startRescan calling bluetoothStatusIsOn");
				bluetoothStatusIsOn();
			} else {
				myTrace("in startRescan but already scanning, so returning");
				return;
			}
		}
	}
}