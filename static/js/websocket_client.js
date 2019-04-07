'use strict';

var WSClient = function (socket_link) {
    this.link = socket_link;

    this.is_in_connection_retrieval = true;
    this.unsuccessful_connection_tries = 0;

    if (socket_link !== '') {
        this.link = socket_link;
        this.ws = this.try_to_connect_again_in_(0);
    } else {
        console.log('[ WebSocket ] Will not connect to socket without $conf{WEBSOCKET_URL}. It\'s normal if you haven\'t configured WebSockets');
    }
};
WSClient.prototype = {
    on_message: function (event) {
        var message = null;
        try {
            message = JSON.parse(event.data);
        } catch (Error) {
            console.log("[ WebSocket ] Failed to parse JSON: " + event.data);
            return;
        }

        var seq = message['seq'] ? message['seq'] : 0;

        switch (message['type']) {
            // Technical handlers
            case 'close':
                this.ws.close(1000); // Normal
                console.log("[ WebSocket ] Connection closed by server : " + (message.reason ? message.reason : 'reason unknown'));
                break;
            case 'ping':
                this.ws.send(JSON.stringify({type: 'pong', seq: seq}));
                break;
            case 'pong':
                Events.emit("WebSocket.ping_success");
                break;
            // All other
            default:
                Events.emit('message', message);
                this.ws.send(JSON.stringify({type: 'confirm', seq: seq}));
                break;
        }

    },
    established: function () {
        this.is_in_connection_retrieval = false;
        this.unsuccessful_connection_tries = 0;
        Events.emit('WebSocket.connected');
    },
    ping: function () {
        this.ws.send(JSON.stringify({type : 'ping'}));
    },
    request_close_socket: function () {
        this.ws.send(JSON.stringify({type : 'closing'}));
        this.try_to_connect_again = false;
    },
    try_to_connect_again_in_: function (seconds) {
        seconds = Math.min(seconds, 10);

        var self = this;
        this.ws = null;

        self.unsuccessful_connection_tries++;
        if (self.unsuccessful_connection_tries >= 10 || this.try_to_connect_again) {
            console.log('[ WebSocket ] Giving up after %i tries', self.unsuccessful_connection_tries);
            return;
        }

        this.ws = new WebSocket(this.link);

        this.ws.onopen = function () {
            Events.emit('WebSocket.opened');
            console.log("[ WebSocket ] connected");
            self.setup_socket();
        };

        this.ws.onclose = function (code, reason, was_clean) {
            console.log('[ WebSocket ] Close : %s %s %s', code, reason, was_clean)
        };

        this.ws.onerror = function () {
            Events.emit('WebSocket.error');
            console.log('Will try again in %.2f seconds', seconds);
            seconds = parseInt(seconds || 1);
            setTimeout(function () {
                self.try_to_connect_again_in_(seconds * 2)
            }, seconds * 1000);
        };

        return this.ws;

    },
    setup_socket: function () {
        var self = this;

        this.ws.onclose = function () {
            if (!self.is_in_connection_retrieval) {
                self.is_in_connection_retrieval = true;
                self.try_to_connect_again_in_(2 + Math.random());
            }
        };

        this.ws.onerror = function () {
            Events.emit('WebSocket.error');
            if (!self.is_in_connection_retrieval) {
                self.is_in_connection_retrieval = true;
                self.try_to_connect_again_in_(2 + Math.random());
            }
        };

        this.ws.onmessage = self.on_message.bind(self);

        Events.once("WebSocket.ping_success", function () {
            self.established();
        });

        this.ping();
    },
};
document.onunload = function () {
    ws.request_close_socket()
    ws.unsuccessful_connection_tries = 1000;
};
