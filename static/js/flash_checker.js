'use strict';
var ws = null;
var devicesList = null;

function processMessage(message) {
    var debugStr = $('<p>').text(JSON.stringify(message));
    $('div#debug').append(debugStr);

    switch (message['type']) {
        case 'connected':
            devicesList.add(DevicesList.prototype.createUsbDevice(message['device']));
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
    createUsbDevice: function (devInfo) {
        var id = devInfo['DeviceID'];
        return new USBDevice(id, devInfo);
    },
    add: function (usbDevice) {
        this.devices[usbDevice.getId()] = usbDevice;
    },
    remove: function (deviceId) {
        delete this.devices[deviceId];
    },
    renew: function (deviceInfoList) {
        var self = this;
        deviceInfoList.forEach(function (devInfo) {
            self.add(self.createUsbDevice(devInfo));
        });
    },
    toHtml: function () {
        var deviceIds = Object.keys(this.devices);

        var flash_views;
        if (deviceIds.length > 0) {
            var self = this;
            flash_views = deviceIds.map(function (id) {
                return self.devices[id].toHtml()
            });
        } else {
            flash_views = ['No devices connected']
        }

        return '<div id="flash-list" class="">' + flash_views.join('') + '</div>';
    }
};

function USBDevice(id, attributes) {
    this.deviceId = id;
    this.info = attributes;

    this.template = $('#usb-template').html();
    Mustache.parse(this.template);
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
        var inKb = sizeInBytes / 1024;
        var inMb = inKb / 1024;
        var inGb = inMb / 1024;
        return inGb.toFixed(2) + 'Gb';
    },
    getActions: function () {

    },
    getRootName: function () {
        return this.info['DeviceID'];
    },
    getDescription: function () {
        return this.info['Description'];
    },
    toHtml: function () {
        return Mustache.render(this.template, {
            id: this.getId(),
            root: this.getRootName(),
            name: this.getDescription(),
            format: this.info['FileSystem'],
            size: this.getSizeGb()
        })
    }
};

$(function () {
    Events.on('WebSocket.error', function () {
       console.log('error');
    });
    Events.once('WebSocket.connected', function () {
        devicesList = new DevicesList();
        Events.on('message', processMessage);
        ws.send({type: 'request_list'});
    });

    ws = new WSClient(OPTIONS['websocket_url']);
});

document.onunload = function () {
    ws.request_close_socket()
};

