'use strict';
var ws = null;
var devicesList = null;

function processMessage(message) {
    var debugStr = $('<p>').text(JSON.stringify(message));
    $('div#debug').append(debugStr);

    switch (message['type']) {
        case 'connected':
            var device = new USBDevice(message['id'], message['device']);
            console.log(device);
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

    $('div#flash-container').html(devicesList.toHtml());

}

function DevicesList() {
    this.devices = {};
}

DevicesList.prototype = {
    add: function (usbDevice) {
        this.devices[usbDevice.getId()] = usbDevice;
    },
    remove: function (deviceId) {
        delete this.devices[deviceId];
    },
    renew: function (deviceInfoList) {
        var self = this;
        deviceInfoList.forEach(function (devInfo) {
            var id = devInfo['VolumeSerialNumber'];
            self.add(new USBDevice(id, devInfo));
        });
    },
    toHtml: function () {
        var deviceIds = Object.keys(this.devices);

        var self = this;
        var flash_views = deviceIds.map(function (id) {
            return self.devices[id].toHtml()
        });

        return '<ul id="flash-list">' + flash_views.join() + '</ul>';
    }
};

function USBDevice(id, attributes) {
    this.deviceId = id;
    this.info = attributes;
}

USBDevice.prototype = {
    getId: function () {
        return this.deviceId;
    },
    getInfo: function () {
        return this.info;
    },
    getSizeGb: function () {
        var sizeInBytes = this.info.Size;
        return (sizeInBytes / 1024 * 1024 * 1024).toFixed(3)
    },
    toHtml: function () {
        return '<li data-id="' + this.info['VolumeSerialNumber'] + '">'
            + '<span class="usb-name">' + this.info['VolumeSerialNumber'] + '</span>'
            + '<span class="usb-format">' + this.info['FileSystem'] + '</span>'
            + '<span class="usb-size">' + this.getSizeGb() + ' Gb</span>' +
            // +'<span class="usb-actions">' + this.info['VolumeSerialNumber'] + '</span>'
            +'</li>'
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

