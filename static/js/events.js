'use strict';

/**
 Events, v2.0.0
 Created by Anton Horodchuk for the ABillS Framework, http://abills.net.ua/
 MIT License

 Simple JavaScript Event PubSub implementation

 One can install listener for event with 'on'

 events.on('eventhappened', function(data){ console.log(data) });
 events.emit('eventhappened', 'Hello, async world') // 'Hello, async world'

 Sometimes you need to remove listeners in long time running application.
 There are three separate interfaces for it.
 1. Use returned object
 var eventHandler = events.on('eventhappened', function(data){ console.log(data) });
 // Do something here
 eventHandler.remove();

 Also you can set one time callback (will do exactly the same as the code above)
 events.once('eventhappened', function(data){ console.log(data) });

 2. Use named function and remove it explicitly
 events.on('eventhappened', doSomeEventBasedAction);
 // Later in your code
 events.off('eventhappened', doSomeEventBasedAction);

 3. Remove all listeners for event (Use with care)
 events.off('eventhappened');

 */
function EventGuard(parent, topic, index) {
    this.parent = parent;
    this.topic  = topic;
    this.index  = index;
}
EventGuard.prototype.remove = function () {
    delete this.parent.topics[this.topic][this.index];
};
function EventsAbstract() {
    this.debug  = 0;
    this.topics = {};
}
/**
 * Set listener for event
 * @param topic
 * @param listener
 * @returns {{remove: remove}}
 */
EventsAbstract.prototype.on = function (topic, listener) {
    if (this.debug > 1) console.log('[ Events ] listen to :', topic);
    if (this.debug > 3) console.trace();
    this.topics[topic] = this.topics[topic] || [];

    return new EventGuard(this, topic, this.topics[topic].push(listener) - 1);
};
/**
 * Remove given listener for event or all if no listener specified
 * @param topic
 * @param listener
 */
EventsAbstract.prototype.off = function off(topic, listener) {
    if (this.debug > 1) console.log('[ Events ] off for :', topic);
    if (this.topics[topic]) {
        if (typeof listener === 'function') {
            for (var i = 0; i < this.topics[topic].length; i++) {
                if (this.topics[topic][i] === listener) {
                    this.topics[topic].splice(i, 1);
                    break;
                }
            }
        }
        else {
            // Clear all listeners
            this.topics[topic] = [];
        }
    }
};
/**
 * Set listener that will be removed after call
 * @param topic
 * @param listener
 */
EventsAbstract.prototype.once = function once(topic, listener) {
    if (this.debug > 1) console.log('[ Events ] once to :', topic);

    var guard;
    guard = this.on(topic, function (data) {
        listener(data);
        guard.remove();
    });
};
/**
 * Run all subscribed listeners
 * @param topic
 * @param data
 */
EventsAbstract.prototype.emit = function emit(topic, data) {
    if (this.debug !== 0) {
        console.log('[ Events ] emmitted :', topic);
        if (this.debug > 2) console.trace();
    }
    if (this.topics[topic]) {
        this.topics[topic].forEach(function (fn) {
            fn(data);
        });
    }
};
EventsAbstract.prototype.emitAsCallback = function (topic) {
    return function (data) {
        Events.emit(topic, data);
    }
};
/**
 * Allows to enable debugInfo
 * @param level
 */
EventsAbstract.prototype.setDebug = function setDebug(level) {
    this.debug = level;
};
var Events = new EventsAbstract();