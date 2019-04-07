'use strict';
var ws = null;
var devicesList = null;

function processMessage(message) {
    var debugStr = $('<p>').text(JSON.stringify(message));
    $('div#debug').append(debugStr);

    switch (message['type']) {
        case 'connected':
            var device = new USBDevice(message['device']);
            devicesList.add(device);
            break;
        case 'removed':
            devicesList.remove(message['id']);
            break;
        case 'restarted':
            ws.send({type: 'request_list'});
            break;
        case 'list':
            devicesList.renew(message['devices']);
            break;
        default:
            console.log("I'm not very smart indeed :)" + JSON.stringify(message))
    }
}

function DevicesList() {
    this.devices = {};
}

DevicesList.prototype = {
    add: function (usbDevice) {
        console.log('add ', usbDevice)
    },
    remove: function (deviceId) {
        console.log('remove ', deviceId);

    },
    renew: function (deviceInfoList) {
        console.log('renew ', deviceInfoList);
    }
};

function USBDevice(attributes) {
    this.deviceId = attributes.id;
    this.info = attributes;
}

USBDevice.prototype = {
    getInfo: function () {
        return this.info;
    }
};

$(function () {

    Events.on('WebSocket.connected', function () {
        devicesList = new DevicesList();
        Events.on('message', processMessage);
        ws.send({type: 'request_list'});
    });

    ws = new WSClient(OPTIONS['websocket_url']);
});

document.onunload = function () {
    ws.request_close_socket()
};

