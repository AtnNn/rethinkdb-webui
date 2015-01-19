# Copyright 2010-2012 RethinkDB, all rights reserved.

# The system database
window.system_db = 'rethinkdb'

$ ->
    # Load the raw driver
    window.r = require('rethinkdb')

    # Create a driver - providing sugar on top of the raw driver
    window.driver = new Driver

    # Some views backup their data here so that when you return to them
    # the latest data can be retrieved quickly.
    window.view_data_backup = {}

    window.main_view = new MainView.MainContainer()
    $('body').html main_view.render().$el


    # We need to start the router after the main view is bound to the DOM
    main_view.start_router()

    Backbone.sync = (method, model, success, error) ->
        return 0

    DataExplorerView.Container.prototype.set_docs reql_docs

class @Driver
    constructor: (args) ->
        if window.location.port is ''
            if window.location.protocol is 'https:'
                port = 443
            else
                port = 80
        else
            port = parseInt window.location.port
        @server =
            host: window.location.hostname
            port: port
            protocol: if window.location.protocol is 'https:' then 'https' else 'http'
            pathname: window.location.pathname

        @hack_driver()

        @state = 'ok'
        @timers = {}
        @index = 0
    
    # Hack the driver: remove .run() and add private_run()
    # We want run() to throw an error, in case a user write .run() in a query.
    # We'll internally run a query with the method `private_run`
    hack_driver: =>
        TermBase = r.expr(1).constructor.__super__.constructor.__super__
        if not TermBase.private_run?
            that = @
            TermBase.private_run = TermBase.run
            TermBase.run = ->
                throw new Error("You should remove .run() from your queries when using the Data Explorer.\nThe query will be built and sent by the Data Explorer itself.")

    # Open a connection to the server
    connect: (callback) ->
        r.connect @server, callback

    # Close a connection
    close: (conn) ->
        conn.close()

    # Run a query once
    run_once: (query, callback) =>
        @connect (error, connection) =>
            if error?
                # If we cannot open a connection, we blackout the whole interface
                # And do not call the callback
                if window.is_disconnected?
                    if @state is 'ok'
                        window.is_disconnected.display_fail()
                else
                    window.is_disconnected = new IsDisconnected
                @state = 'fail'
            else
                if @state is 'fail'
                    # Force refresh
                    window.location.reload true
                else
                    @state = 'ok'
                    query.private_run connection, (err, result) =>
                        if typeof result?.toArray is 'function'
                            result.toArray (err, result) ->
                                callback(err, result)
                        else
                            callback(err, result)


    # Run the query every `delay` ms - using setTimeout
    # Returns a timeout number (to use with @stop_timer).
    # If `index` is provided, `run` will its value as a timer
    run: (query, delay, callback, index) =>
        if not index?
            @index++
        index = @index
        @timers[index] = {}
        ( (index) =>
            @connect (error, connection) =>
                if error?
                    # If we cannot open a connection, we blackout the whole interface
                    # And do not call the callback
                    if window.is_disconnected?
                        if @state is 'ok'
                            window.is_disconnected.display_fail()
                    else
                        window.is_disconnected = new IsDisconnected
                    @state = 'fail'
                else
                    if @state is 'fail'
                        # Force refresh
                        window.location.reload true
                    else
                        @state = 'ok'
                        if @timers[index]?
                            @timers[index].connection = connection
                            (fn = =>
                                try
                                    query.private_run connection, (err, result) =>
                                        if typeof result?.toArray is 'function'
                                            result.toArray (err, result) =>
                                                # This happens if people load the page with the back button
                                                # In which case, we just restart the query
                                                if err?.message is "This HTTP connection is not open"
                                                    return @run query, delay, callback, index
                                                callback(err, result)
                                                if @timers[index]?
                                                    @timers[index].timeout = setTimeout fn, delay
                                        else
                                            if err?.message is "This HTTP connection is not open"
                                                return @run query, delay, callback, index
                                            callback(err, result)
                                            if @timers[index]?
                                                @timers[index].timeout = setTimeout fn, delay
                                catch err
                                    console.log err
                                    return @run query, delay, callback, index
                            )()
        )(index)
        index

    # Stop the timer and close the connection
    stop_timer: (timer) =>
        clearTimeout @timers[timer]?.timeout
        @timers[timer]?.connection?.close {noreplyWait: false}
        delete @timers[timer]

    # common queries used in multiple places in the ui
    queries:
        all_logs: (limit) =>
            server_conf = r.db(system_db).table('server_config')
            r.db(system_db)
                .table('logs', identifierFormat: 'uuid')
                .orderBy(index: r.desc('id'))
                .limit(limit)
                .map((log) ->
                    log.merge
                        server: server_conf.get(log('server'))('name')
                        server_id: log('server')
                )
        server_logs: (limit, server_id) =>
            server_conf = r.db(system_db).table('server_config')
            r.db(system_db)
                .table('logs', identifierFormat: 'uuid')
                .orderBy(index: r.desc('id'))
                .filter(server: server_id)
                .limit(limit)
                .map((log) ->
                    log.merge
                        server: server_conf.get(log('server'))('name')
                        server_id: log('server')
                )
