# Overview
The software is supposed to allow someone running a bunch of commands for a set of USB storage devices.
Actions that can be performed on a device are stored in the 'config.ini' file as a templates.
**For now, only the DeviceID variable is rendered inside a template.**

## How this is supposed to be used
Check that config contains something meaningful for your setup. 
This chapter will be extended

## ACKNOWLEDGMENTS
The bin folder contains the 'disk-filltest.exe'. It is borrowed from https://github.com/bingmann/disk-filltest \
Mind bingmann's work too and possibly star his repository.


## TODO
 * ~~"Seen" button for operations panel~~
 * ~~Identify the changed devices by hash of concatenated values~~
 * ~~Show real free size in the progress bar (will be an progress for "Check" action)~~
 * Mark operation as success/failure on finish (Ehh... Windows...)
 * ~~Output inside of the operation the panel accordion~~
 * ~~Buttons for bulk operations~~
 * ~~Cancel operation button~~ 
 * * Now debug why it doesn't work and uncomment the button
 * ~~Append Actions to the 'changed' device information~~
 * Debug log in a separate window
 * Acknowledge the master for executor connection before operation started
 * Mechanics to create "support" zip file with all the logs
 * Allow to mask a device ( hide it from the UI ), so you will not format your personal device
 * Allow some configuration to be changed through the UI (Should investigate what should be configured first)
 * Client session persistence (allow to refresh the page, with operations refresh) - client cookie
 * Gradle build
 * Tests :)
 * ~~Logs in a separate folder~~
 * Logs are removed on a startup
 * Make the design look like this is something intended to be used by a human being
 * Browser notification when all operations finished
 * Make a queue for devices (pending operations queue), so you can schedule another operation after current
 
