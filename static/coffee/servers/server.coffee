# Copyright 2010-2015 RethinkDB
# Machine view
# ServerView module

ui_modals = require('../ui_components/modals.coffee')
log_view = require('../log_view.coffee')
vis = require('../vis.coffee')
models = require('../models.coffee')
app = require('../app.coffee')
driver = app.driver
system_db = app.system_db

r = require('rethinkdb')

class ServerContainer extends Backbone.View
    template:
        error: Handlebars.templates['error-query-template']
        not_found: Handlebars.templates['element_view-not_found-template']

    initialize: (id) =>
        @id = id
        @server_found = true

        # Initialize with dummy data so we can start rendering the page
        @server = new models.Server(id: id)
        @responsibilities = new models.Responsibilities
        @server_view = new ServerMainView
            model: @server
            collection: @responsibilities

        @fetch_server()

    fetch_server: =>
        query = r.do(
            r.db(system_db).table('server_config').get(@id),
            r.db(system_db).table('server_status').get(@id),
            (server_config, server_status) ->
                r.branch(
                    server_status.eq(null),
                    null,
                    server_status.merge( (server_status) ->
                        tags: server_config('tags')
                        responsibilities: r.db(system_db).table('table_status'
                        ).orderBy( (table) -> table('db').add('.').add(table('name')) ).map( (table) ->
                            table.merge( (table) ->
                                shards: table("shards").map(r.range(), (shard, index) ->
                                    shard.merge(
                                        index: index.add(1)
                                        num_shards: table('shards').count()
                                        role: r.branch(server_status('name').eq(shard('primary_replica')),
                                            'primary', 'secondary')
                                        )
                                ).filter((shard) ->
                                    shard('replicas')('server').contains(server_status('name'))
                                ).coerceTo('array')
                            )
                        ).filter( (table) ->
                            table("shards").isEmpty().not()
                        ).coerceTo("ARRAY")
                    ).merge
                        id: server_status 'id'
                )
        )

        @timer = driver.run query, 5000, (error, result) =>
            # We should call render only once to avoid blowing all the sub views
            if error?
                @error = error
                @render()
            else
                rerender = @error?
                @error = null
                if result is null
                    rerender = rerender or @server_found
                    @server_found = false
                else
                    rerender = rerender or not @server_found
                    @server_found = true

                    responsibilities = []
                    for table in result.responsibilities
                        responsibilities.push new models.Responsibility
                            type: "table"
                            is_table: true
                            db: table.db
                            table: table.name
                            table_id: table.id
                            id: table.db+"."+table.name

                        for shard in table.shards
                            responsibilities.push new models.Responsibility
                                is_shard: true
                                db: table.db
                                table: table.name
                                index: shard.index
                                num_shards: shard.num_shards
                                role: shard.role
                                id: table.db+"."+table.name+"."+shard.index

                    if not @responsibilities?
                        @responsibilities = new models.Responsibilities responsibilities
                    else
                        @responsibilities.set responsibilities
                    delete result.responsibilities

                    @server.set result

                if rerender
                    @render()

    render: =>
        if @error?
            @$el.html @template.error
                error: @error?.message
                url: '#servers/'+@id
        else
            if @server_found
                @$el.html @server_view.render().$el
            else # The server wasn't found
                @$el.html @template.not_found
                    id: @id
                    type: 'server'
                    type_url: 'servers'
                    type_all_url: 'servers'
        @

    remove: =>
        driver.stop_timer @timer
        @server_view?.remove()
        super()

class ServerMainView extends Backbone.View
    template:
        main: Handlebars.templates['full_server-template']

    events:
        'click .close': 'close_alert'
        'click .operations .rename': 'rename_server'

    rename_server: (event) =>
        event.preventDefault()

        if @rename_modal?
            @rename_modal.remove()
        @rename_modal = new ui_modals.RenameItemModal
            model: @model
        @rename_modal.render()

    # Method to close an alert/warning/arror
    close_alert: (event) ->
        event.preventDefault()
        $(event.currentTarget).parent().slideUp('fast', -> $(this).remove())

    initialize: =>
        @title = new Title
            model: @model

        @profile = new Profile
            model: @model
            collection: @collection

        @stats = new models.Stats
        @stats_timer = driver.run(
            r.db(system_db).table('stats')
            .get(['server', @model.get('id')])
            .do((stat) ->
                keys_read: stat('query_engine')('read_docs_per_sec'),
                keys_set: stat('query_engine')('written_docs_per_sec'),
            ), 1000, @stats.on_result)

        @performance_graph = new vis.OpsPlot(@stats.get_stats,
            width:  564             # width in pixels
            height: 210             # height in pixels
            seconds: 73             # num seconds to track
            type: 'server'
        )

        @responsibilities = new ResponsibilitiesList
            collection: @collection

    render: =>
        #TODO Handle ghost?
        @$el.html @template.main()

        @$('.main_title').html @title.render().$el
        @$('.profile').html @profile.render().$el
        @$('.performance-graph').html @performance_graph.render().$el
        @$('.responsibilities').html @responsibilities.render().$el
        @logs = new log_view.LogsContainer
            server_id: @model.get('id')
            limit: 5
            query: driver.queries.server_logs
        @$('.recent-log-entries').html @logs.render().$el
        @

    remove: =>
        driver.stop_timer @stats_timer
        @title.remove()
        @profile.remove()
        @responsibilities.remove()
        if @rename_modal?
            @rename_modal.remove()
        @logs.remove()

class Title extends Backbone.View
    className: 'server-info-view'
    template: Handlebars.templates['server_view_title-template']
    initialize: =>
        @listenTo @model, 'change:name', @render

    render: =>
        @$el.html @template
            name: @model.get('name')
        @

    remove: =>
        @stopListening()
        super()

class Profile extends Backbone.View
    className: 'server-info-view'
    template: Handlebars.templates['server_view_profile-template']
    initialize: =>
        @listenTo @model, 'change', @render
        @listenTo @collection, 'add', @render
        @listenTo @collection, 'remove', @render

    render: =>
        if @model.get('status') != 'connected'
            if @model.get('connection')? and @model.get('connection').time_disconnected?
                last_seen = $.timeago(
                    @model.get('connection').time_disconnected).slice(0, -4)
            else
                last_seen = "unknown time"

            uptime = null
            version = "unknown"
        else
            last_seen = null
            uptime = $.timeago(
                @model.get('connection').time_connected).slice(0, -4)
            version = @model.get('process').version?.split(' ')[1].split('-')[0]

        if @model.get('network')?
            main_ip = @model.get('network').hostname
        else
            main_ip = ""

        @$el.html @template
            main_ip: main_ip
            tags: @model.get('tags')
            uptime: uptime
            version: version
            num_shards: @collection.length
            status: @model.get('status')
            last_seen: last_seen
            system_db: system_db
        @$('.tag-row .tags, .tag-row .admonition').tooltip
            for_dataexplorer: false
            trigger: 'hover'
            placement: 'bottom'
        @

    remove: =>
        @stopListening()
        super()


class ResponsibilitiesList extends Backbone.View
    template: Handlebars.templates['responsibilities-template']

    initialize: =>
        @responsibilities_view = []

        @$el.html @template

        @collection.each (responsibility) =>
            view = new ResponsibilityView
                model: responsibility
                container: @
            # The first time, the collection is sorted
            @responsibilities_view.push view
            @$('.responsibilities_list').append view.render().$el

        if @responsibilities_view.length > 0
            @$('.no_element').hide()

        @listenTo @collection, 'add', (responsibility) =>
            new_view = new ResponsibilityView
                model: responsibility
                container: @

            if @responsibilities_view.length is 0
                @responsibilities_view.push new_view
                @$('.responsibilities_list').html new_view.render().$el
            else
                added = false
                for view, position in @responsibilities_view
                    if models.Responsibilities.prototype.comparator(view.model, responsibility) > 0
                        added = true
                        @responsibilities_view.splice position, 0, new_view
                        if position is 0
                            @$('.responsibilities_list').prepend new_view.render().$el
                        else
                            @$('.responsibility_container').eq(position-1).after new_view.render().$el
                        break
                if added is false
                    @responsibilities_view.push new_view
                    @$('.responsibilities_list').append new_view.render().$el

            if @responsibilities_view.length > 0
                @$('.no_element').hide()

        @listenTo @collection, 'remove', (responsibility) =>
            for view, position in @responsibilities_view
                if view.model is responsibility
                    responsibility.destroy()
                    view.remove()
                    @responsibilities_view.splice position, 1
                    break

            if @responsibilities_view.length is 0
                @$('.no_element').show()



    render: =>
        @

    remove: =>
        @stopListening()
        for view in @responsibilities_view
            view.model.destroy()
            view.remove()
        super()


class ResponsibilityView extends Backbone.View
    className: 'responsibility_container'
    template: Handlebars.templates['responsibility-template']

    initialize: =>
        @listenTo @model, 'change', @render

    render: =>
        @$el.html @template @model.toJSON()
        @

    remove: =>
        @stopListening()
        super()

module.exports =
    ServerContainer: ServerContainer
    ServerMainView: ServerMainView
    Title: Title
    Profile: Profile
    ResponsibilitiesList: ResponsibilitiesList
    ResponsibilityView: ResponsibilityView
