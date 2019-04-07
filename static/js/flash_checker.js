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
            ws.send(JSON.stringify({ type: 'request_list' }));
            break;
        default:
            console.log("I'm not very smart indeed :)" + JSON.stringify(message))
    }


}

function DevicesList() {
  this.devices = {};
}

DevicesList.prototype = {
    add: function(usbDevice){},
    remove: function (deviceId) {

    }
};

function USBDevice(attributes) {
    this.deviceId = attributes.id;
    this.info = attributes;
}

USBDevice.prototype = {
    getInfo : function (){
        return this.info;
    }
};


var ws = null;
$(function () {
    console.log('ready');
    ws = new WSClient(OPTIONS['websocket_url']);
});
Events.on('message', processMessage);
