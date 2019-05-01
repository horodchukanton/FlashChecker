'use strict';
var ws = null;
var devicesList = null;
var usbTemplate = null;
var operations = null;

function processMessage(message) {
    var debugStr = $('<p>').text(JSON.stringify(message));
    $('div#debug').append(debugStr);

    var messageType = message['type'];

    // Determining special actions
    if (operations.isResponsibleFor(messageType)) {
        operations.onMessage(message)
    } else if (devicesList.isResponsibleFor(messageType)) {
        devicesList.onMessage(message);
        Events.emit('devices_renewed');
    } else {
        switch (messageType) {
            case 'restarted':
                ws.send({type: 'request_list'});
                break;
            case 'error':
                alert(message['message'] || 'undefined error');
                break;
            default:
                console.log("I'm not very smart indeed :)" + JSON.stringify(message))
        }
    }
}

function onActionButtonClicked() {
    var $this = $(this);
    var deviceId = $this.attr('data-deviceId');
    var action = $this.attr('data-action');
    console.log("Clicked: %s, %s", deviceId, action);
    operations.invokeAction(action, deviceId, $this);
}

function Operations() {
    this.sequence = 0;
    this.pending = [];
    this.running = {};
}

Operations.prototype = {
    _message_types: [
        'action_accepted',
        'worker_action_started',
        'worker_event'
    ],
    isResponsibleFor: function (messageType) {
        return this._message_types.indexOf(messageType) >= 0
    },
    onMessage: function (message) {
        var token = message['token'];
        var operation;

        switch (message['type']) {
            case 'action_accepted':
                var sequence = message['request_num'];
                operation = this.pending.filter(function (value) {
                    return value['request_num'] === sequence
                })[0];
                operation['state'] = 'started';
                this.running[token] = operation;
                break;
            case 'worker_action_started':
                // Find the operation
                operation = this.running[token];
                operation['state'] = 'running';
                // Run the progress bar
                break;
            case 'worker_event':
                operation = this.running[token];
                if (message['event']['type'] === 'worker_child_finished') {
                    operation.state = 'finished';
                }
                break;
            default:
                console.log("Operations received wrong message:", message);
        }
        Events.emit(message['type'], operation);
    },
    invokeAction: function (action, deviceId, $button) {
        if (!action && deviceId) {
            alert("Oops. No action or deviceID. Renew the page.")
        }
        var requestNumber = ++this.sequence;
        var newOperation = {
            action: action,
            device_id: deviceId,
            request_num: requestNumber,
            type: 'action_request'
        };

        // HARM: result can return before we save the reference
        ws.send(newOperation);

        // Add it to temporary
        newOperation['button'] = $button;
        newOperation['state'] = 'pending';
        this.pending.push(newOperation);
    }
};

function DevicesList($html) {
    this.devices = {};
    this.$html = $html;

    var self = this;
    Events.on('devices_renewed', function () {
        self.renewHtml()
    });
}

DevicesList.prototype = {
    _message_types: ['connected', 'removed', 'list'],
    isResponsibleFor: function (messageType) {
        return this._message_types.indexOf(messageType) >= 0
    },
    onMessage: function (message) {
        switch (message['type']) {
            case 'connected':
                this.add(this.createUsbDevice(message['device']));
                break;
            case 'removed':
                this.remove(message['id']);
                break;
            case 'list':
                this.renew(message['devices']);
                break;
            default:
                console.log("DevicesList received wrong message:", message)
        }
    },
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
    renewHtml: function () {
        this.$html.html(this.toHtml());
        this.$html.find('button.btn-action').on('click', onActionButtonClicked);
    },
    toHtml: function () {
        var deviceIds = Object.keys(this.devices);

        var $div_list = $('<div></div>', {'id': 'flash-list'});

        if (deviceIds.length > 0) {
            for (var i = 0; i < deviceIds.length; i++) {
                var id = deviceIds[i];
                $div_list.append(this.devices[id].toHtml())
            }
        } else {
            $div_list.append('No devices');
        }

        return $div_list;
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
        var inKb = sizeInBytes / 1024;
        var inMb = inKb / 1024;
        var inGb = inMb / 1024;
        return inGb.toFixed(2) + 'Gb';
    },
    getActions: function () {
        return this.info['Actions'];
    },
    getRootName: function () {
        return this.info['DeviceID'];
    },
    getDescription: function () {
        return this.info['Description'];
    },
    toHtml: function () {
        var rendered = Mustache.render(usbTemplate, {
            id: this.getId(),
            root: this.getRootName(),
            name: this.getDescription(),
            format: this.info['FileSystem'],
            size: this.getSizeGb(),
            actions: this.getActions()
        });

        this.$html = $(rendered);

        return this.$html;
    }
};

$(function () {
    Events.on('WebSocket.error', function () {
        console.log('error');
    });

    Events.once('WebSocket.connected', function () {
        devicesList = new DevicesList($('div#flash-container'));
        operations = new Operations($('div#operations-container'));

        Events.on('message', processMessage);
        ws.send({type: 'request_list'});
    });

    // Connecting to the server
    ws = new WSClient(OPTIONS['websocket_url']);

    // Parsing USB template
    usbTemplate = $('#usb-template').html();
    Mustache.parse(usbTemplate);
});

document.onunload = function () {
    ws.request_close_socket()
};

