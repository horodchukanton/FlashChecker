'use strict';
var ws = null;
var devicesList = null;
var usbTemplate = null;
var operationTemplate = null;
var operations = null;
var bulkActions = null;

function processMessage(message) {
    var debugStr = $('<p>').text(JSON.stringify(message));
    $('div#debug').append(debugStr);

    var messageType = message['type'];

    // Determining special actions
    if (operations.isResponsibleFor(messageType)) {
        operations.onMessage(message)
    } else if (devicesList.isResponsibleFor(messageType)) {
        devicesList.onMessage(message);
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

function Operations($container) {
    this.sequence = 0;
    this.pending = [];
    this.running = {};
    this.$container = $container;

    this.updateView();

    // Initialize seen button
    $('button#operations-seen-button').on('click', this.onSeenClicked.bind(this));
}

Operations.prototype = {
    _message_types: [
        'action_accepted',
        'action_canceled',
        'worker_action_started',
        'worker_output',
        'worker_action_finished',
        'worker_event',
        'operation_event'
    ],
    isResponsibleFor: function (messageType) {
        return this._message_types.indexOf(messageType) >= 0
    },
    onMessage: function (message) {
        var token = message['token'];
        var operation;

        switch (message['type']) {
            case 'action_accepted':
                operation = this.onActionAccepted(message, token);
                var view = this.getOperationView(token);
                console.log(view);
                this.appendOperationView(view);
                break;
            case 'worker_action_started':
                // Find the operation
                operation = this.findOperation(token);
                operation['state'] = 'running';
                this.setOperationViewClass(token, 'info');
                break;
            case 'worker_output':
                var output = message['event']['content'];
                this.getOutputBody(token)
                    .append($('<p></p>').text(output));
                break;
            case 'worker_action_finished':
                operation = this.onActionFinished(message, token);
                break;
            case 'worker_event':
                operation = this.findOperation(token);
                break;
            case 'operation_event':
                if (message['event']['type'] === 'operation_removed') {
                    // Delete view
                    var view = this.getOperationView(token);
                    view.remove();

                    // Delete from cache
                    delete this.running[token];
                }
                break;
            default:
                console.log("Operations received wrong message:", message);
        }
        Events.emit(message['type'], operation);
    },
    findOperation: function (token) {
        var operation = this.running[token];
        if (typeof (operation) === 'undefined') {
            console.trace();
            throw "Somebody looked for an unexisting operation"
        }
        return operation;
    },
    getOperationView: function (token) {
        var $found = this.$container.find('div#operation-' + token);
        if ($found.length < 1) {
            $found = this.renderOperationView(token);
            this.appendOperationView($found);
        }

        return $found;
    },
    appendOperationView: function (view) {
        this.$container.find('div#operations-list')
            .append(view);
    },
    renderOperationView: function (token) {
        var op = this.findOperation(token);
        var view = Mustache.render(operationTemplate, {
            token: token,
            deviceId: op.device_id,
            action: op.action
        });

        var $view = $(view);

        var self = this;
        $view.find('button.operation-seen-button').on('click', function () {
            self.onOperationSeenClicked(token);
        });

        $view.find('button.operation-cancel-button').on('click', function () {
            self.onOperationCancelClicked(token);
        });

        return $view;
    },
    setOperationViewClass: function (token, new_class) {
        var view = this.getOperationView(token);
        var panel = view.find('div.operation-panel');
        panel.removeClass('panel-default');
        panel.removeClass('panel-success');
        panel.removeClass('panel-info');
        panel.removeClass('panel-warning');
        panel.removeClass('panel-danger');
        panel.addClass('panel-' + new_class);
    },
    getOutputBody: function (token) {
        var view = this.getOperationView(token);
        return view.find('div#collapse' + token).find('div.panel-body')
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

        // Creating a copy with only this properties
        var message = Object.assign({}, newOperation);

        // Adding other properties and saving
        newOperation['button'] = $button;
        newOperation['state'] = 'pending';
        this.pending.push(newOperation);

        // Sending request
        ws.send(message);

        // Will proceed in an 'action_accepted' callback
    },
    onActionAccepted: function (message, token) {
        var sequence = message['request_num'];

        // Find the pending one
        var index = -1;
        for (var i = 0; i < this.pending.length; i++) {
            if (this.pending[i]['request_num'] === sequence) {
                index = i;
                break;
            }
        }

        if (index < 0) {
            throw new Error("Accepted operation that was not pending");
        }

        var operation = this.pending[index];
        operation['state'] = 'started';
        this.running[token] = operation;

        // Remove pending
        this.pending.splice(index, 1);

        Events.emit('device_renewed', operation['device_id']);

        return operation;
    },
    onActionFinished: function (message, token) {
        var operation = this.findOperation(token);
        console.log('finished', message);
        operation['state'] = 'finished';

        var exit_code = message['event']['exit_code'];
        var child_pid = message['event']['child_pid'];

        var new_class = 'success';
        // Ehh... Windows
        if (exit_code === child_pid) {
            new_class = 'success'
        } else if ('canceled' === exit_code) {
            new_class = 'warning'
        } else {
            console.warn("Create GitHub issue to add the Linux exit code support, exit: %s, pid: %s", exit_code, child_pid);
        }
        this.setOperationViewClass(token, new_class);
        this.getOperationView(token).find('button.operation-cancel-button').remove();
        return operation;
    },
    onSeenClicked: function () {
        ws.send({type: 'action_all_operations_seen'});
    },
    onOperationCancelClicked: function (token) {
        // TODO: confirm
        ws.send({type: 'action_cancel_operation', token: token});
    },
    onOperationSeenClicked: function (token) {
        ws.send({type: 'action_operation_seen', token: token});
    },
    isRunningFor: function (deviceId) {
        var tokens = Object.keys(this.running);
        for (var i = 0; i < tokens.length; i++) {
            if (this.running[tokens[i]]['device_id'] === deviceId) {
                return true
            }
        }
        return false;
    },
    render: function () {
        var tokens = Object.keys(this.running);
        var $rendered = $('<div></div>', {id: 'operations-list'});
        for (var i = 0; i < tokens.length; i++) {
            $rendered.append(this.getOperationView(tokens[i]));
        }
        return $rendered;
    },
    toHtml: function (renew) {
        if (typeof (this.$view) !== 'undefined' && !renew) {
            return this.$view;
        }

        this.$view = this.render();

        return this.$view;
    },
    updateView: function () {
        var newView = this.toHtml(true);
        $(this.$container).html(newView)
    }
};


function DevicesList($container) {
    this.devices = {};
    this.$container = $container;

    var self = this;
    Events.on('devices_renewed', function () {
        self.renewHtml()
    });
    Events.on('device_renewed', function (id) {
        self.devices[id].toHtml(true);
        self.renewHtml()
    })
}

DevicesList.prototype = {
    _message_types: ['connected', 'removed', 'list', 'changed'],
    isResponsibleFor: function (messageType) {
        return this._message_types.indexOf(messageType) >= 0
    },
    onMessage: function (message) {
        switch (message['type']) {
            case 'connected':
                var device = this.createUsbDevice(message['device'])
                this.add(device);
                this.renewHtml();
                break;
            case 'removed':
                this.remove(message['id']);
                this.renewHtml();
                break;
            case 'changed':
                this.renewDevice(message['id'], message['device']);
                break;
            case 'list':
                this.renewDevices(message['devices']);
                this.renewHtml();
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
        bulkActions.updateActions(usbDevice.getActions());
    },
    renewDevice: function (deviceId, newInfo) {
        var device = this.devices[deviceId];

        if (!newInfo['Actions']) {
            newInfo['Actions'] = device['info']['Actions'];
        }

        device.info = newInfo;

        // Renew cached view
        device.toHtml(true);

        this.renewHtml();
    },
    remove: function (deviceId) {
        delete this.devices[deviceId];
    },
    renewDevices: function (deviceInfoList) {
        var self = this;
        deviceInfoList.forEach(function (devInfo) {
            self.add(self.createUsbDevice(devInfo));
        });
    },
    renewHtml: function () {
        this.$container.html(this.toHtml(true));

        // Avoiding duplicate handlers
        this.$container.find('button.btn-action').off('click', onActionButtonClicked);
        this.$container.find('button.btn-action').on('click', onActionButtonClicked);
    },
    toHtml: function (renew) {
        if (typeof (this.$view) !== 'undefined' && !renew) {
            return this.$view;
        }
        var deviceIds = Object.keys(this.devices);
        var $div_list = $('<div></div>', {'id': 'flash-list'});

        if (deviceIds.length > 0) {
            for (var i = 0; i < deviceIds.length; i++) {
                var id = deviceIds[i];
                $div_list.append(this.devices[id].toHtml())
            }
        } else {
            $div_list.append('<p>No devices</p>');
        }

        this.$view = $div_list;

        return this.$view;
    }
};

function USBDevice(id, attributes) {
    this.deviceId = id;
    this.info = attributes;
    this.$view = null;
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
    render: function () {
        var progress = (100 / (this.info['Size'] / (this.info['Size'] - this.info['FreeSpace'])));
        var rendered = Mustache.render(usbTemplate, {
            id: this.getId(),
            root: this.getRootName(),
            name: this.getDescription(),
            format: this.info['FileSystem'],
            size: this.getSizeGb(),
            actions: this.getActions(),
            progress: progress
        });

        return $(rendered);
    },
    toHtml: function (renew) {
        if (typeof (this.$view) !== 'undefined' && !renew) {
            this.$view = this.render()
        }
        return this.$view;
    },
    setProgress: function (current, total) {
        this.progress = 100 / (total / current);
        this.renewProgressBar();
    },
    renewProgressBar: function () {
        var $progressBar = this.$view.find('div.progress-bar');

        if (operations.isRunningFor(this.getId())) {
            $progressBar.addClass('active');
        }

        this.progress = this.progress || 0;
        $progressBar.attr({style: "width:" + this.progress + '%' + ";"});
    }
};

function BulkActionsHandler($container) {
    this.actions = [];
    this.$container = $container;
}

BulkActionsHandler.prototype = {
    render: function () {
        this.$container.empty();
        for (var i = 0; i < this.actions.length; i++) {
            var action = this.actions[i];

            var $button = $('<button></button>');
            $button.addClass('btn btn-primary');
            $button.attr('data-action', action);
            $button.text(action + ' All');

            var self = this;
            $button.on('click', function () {
                var $this = $(this);
                var action = $this.attr('data-action');

                // noinspection JSReferencingMutableVariableFromClosure
                self.invokeBulkAction(action, $this);
            });

            this.$container.append($button);
        }
    },
    invokeBulkAction: function (action, $button) {
        var deviceIds = Object.keys(devicesList.devices);
        for (var i = 0; i < deviceIds.length; i++) {
            if (operations.isRunningFor(deviceIds[i])) {
                continue;
            }
            operations.invokeAction(action, deviceIds[i], $button);
        }
    },
    updateActions: function (newActions) {
        var hasNew = false;
        for (var i = 0; i < newActions.length; i++) {
            if (this.actions.indexOf(newActions[i]) === -1) {
                this.actions.push(newActions[i]);
                hasNew = true;
            }
        }
        if (hasNew) {
            this.render();
        }
    }
};

$(function () {
    Events.on('WebSocket.error', function () {
        console.log('error');
    });

    Events.once('WebSocket.connected', function () {
        devicesList = new DevicesList($('div#flash-container'));
        operations = new Operations($('div#operations-container'));
        bulkActions = new BulkActionsHandler($('div#bulk-actions'));

        Events.on('message', processMessage);
        ws.send({type: 'request_list'});
    });

    // Connecting to the server
    ws = new WSClient(OPTIONS['websocket_url']);

    // Parsing USB template
    usbTemplate = $('#usb-template').html();
    Mustache.parse(usbTemplate);

    operationTemplate = $('#operation-template').html();
    Mustache.parse(operationTemplate);

});

document.onunload = function () {
    ws.request_close_socket()
};