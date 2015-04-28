$ = require 'jquery'
_ = require 'lodash'

L.mapbox.accessToken = '<MAPBOX ACCESS TOKEN>'

southWest = L.latLng 37.7072, -122.5868
northEast = L.latLng 37.8339, -122.3554
bounds = L.latLngBounds southWest, northEast

map = L.mapbox.map 'map', '<MAPBOX PROJECT ID>',
  maxBounds: bounds
  maxZoom: 20
  minZoom: 13
  attributionControl: false
  zoomControl: false

map
  .fitBounds bounds
  .setView [37.778, -122.426], 15

new L.Control.Zoom position: 'bottomright'
  .addTo map

FacilityT = 
  'BIKE ROUTE': '3, 3'
  'BIKE LANE': ''
  'BIKE PATH': '5, 10'

Colors = ['#2ECC71', '#3498DB', '#E74C3C']

getStyle = (type, color) ->
  lineCap: 'square'
  weight: 3
  opacity: 1
  color: Colors[color]
  fillColor: Colors[color]
  dashArray: FacilityT[type]
  fillOpacity: 0.7

startMarker = L.marker new L.LatLng(37.7787880226612, -122.42438793182373),
  icon: L.mapbox.marker.icon
    'marker-color': '#FF8888'
    'marker-symbol': 'bicycle'
  draggable: true

startMarker.on 'click', () ->
  console.log startMarker.getLatLng()

endMarker = L.marker new L.LatLng(37.7787880226612, -122.41507530212402),
  icon: L.mapbox.marker.icon
    'marker-color': '#3498DB'
    'marker-symbol': 'bicycle'
  draggable: true

startMarker .addTo map
endMarker.addTo map

layerGroup = L.layerGroup()
layerGroup.addTo map

layerGroup2 = L.layerGroup()
layerGroup2.addTo map

layers = []

getEdge = (path, edge) ->
  line1 = parseJSON edge.line1
  line2 = parseJSON edge.line2
  path = parseJSON path.geometry

  for coordinates, index in [line1.coordinates[0], line2.coordinates[line2.coordinates.length - 1]]
    if _.isEqual(coordinates, path.coordinates[0]) or 
       _.isEqual(coordinates, path.coordinates[path.coordinates.length - 1])

      return \
        barrier: edge.barrier, 
        facilityT: edge.facilityT, 
        geometry: edge["line#{index + 1}"]

  return null

drawLine = (marker, nearestBikePath) ->
  return unless nearestBikePath?

  geoJson = 
    type: 'Feature'
    geometry: 
      type: 'LineString'
      coordinates: [
        [marker[0], marker[1]]
        [nearestBikePath[0], nearestBikePath[1]]
      ]

  layer = L.geoJson geoJson, style: ->
    fillColor: '#9B59B6',
    weight: 2,
    opacity: 1,
    color: '#9B59B6',
    dashArray: '',
    fillOpacity: 0.7

  layer.addTo map

  layerGroup2.addLayer layer

getConnectionPoint = (route1, route2) ->
  return route1.geometry.coordinates if route1.geometry.type is 'Point'

  coordsLength1 = route1.geometry.coordinates.length
  coordsLength2 = route2.geometry.coordinates.length

  for coordinate1 in [route1.geometry.coordinates[0], route1.geometry.coordinates[coordsLength1 - 1]]
    isEndpoint = false

    for coordinate2 in [route2.geometry.coordinates[0], route2.geometry.coordinates[coordsLength2 - 1]]
      if _.isEqual coordinate1, coordinate2
        isEndpoint = true

    return coordinate1 if not isEndpoint

  return null

parseJSON = (jsonString) ->
  try
    return $.parseJSON jsonString
  catch e
    console.log e

    return {}

showAlert = (message, hideButton = false) ->
  _alert = $ '#alert'

  _alert
    .removeClass 'hidden'
    .find 'div.message'
    .html message

  $ '#overlay'
    .removeClass 'hidden'

  width = _alert.outerWidth()
  height = _alert.outerHeight()

  _alert.css
    marginTop: "-#{height / 2}px"
    marginLeft: "-#{width / 2}px"

  if hideButton
    _alert.find 'button'
      .hide()

  return

closeAlert = ->
  _alert = $ '#alert'

  _alert
    .addClass 'hidden'
    .find 'button'
    .show()

  $ '#overlay'
    .addClass 'hidden'

$ '#close-alert'
  .on 'click', ->
    closeAlert()

    return

$ 'div.result'
  .on 'click', ->
    return unless layers?
    return unless layers.length > 0

    _this = $ this
    _this.toggleClass 'shown'

    index = _this.index()

    _this
      .find 'i'
      .toggleClass 'fa-eye fa-eye-slash'
    
    if _this.is '.shown'
      layerGroup.clearLayers()

      showIndexes = []

      $ 'div.result'
        .each (index) ->          
          _this = $ this
          showIndexes.push index if _this.is '.shown'

          return
      
      showIndexes.reverse()

      for index in showIndexes   
        for subLayer in layers[index]
          layerGroup.addLayer subLayer

    else
      for subLayer in layers[index]
        layerGroup.removeLayer subLayer

    return

$ '#find-bike-routes'
  .on 'click', ->
    _this = $ this
    
    _this.prop 'disabled', true

    $ 'div.results'
      .addClass 'hidden'

    layers = []
    layerGroup.clearLayers()
    layerGroup2.clearLayers()

    startPoint = startMarker.getLatLng()
    endPoint = endMarker.getLatLng()

    request = $.get "http://sfhired-jorje.rhcloud.com/paths/#{startPoint.lng}/#{startPoint.lat}/#{endPoint.lng}/#{endPoint.lat}"

    showAlert 'Finding shortest paths...', true

    request.done (data) ->
      closeAlert()

      try
        paths = data.paths
        
        unless paths?
          showAlert 'Sorry, no data available. Please try again.<br><em>Note: Try to reverse the markers.</em>'

          _this.prop 'disabled', false

          return

        startEdge = getEdge paths[0], data.startEdge
        endEdge = getEdge paths[paths.length - 1 ], data.endEdge     

        previousRouteID = null
        routes = []

        for path in paths
          if previousRouteID == null or previousRouteID != path.routeID
            routes[path.routeID] = []
          
          routes[path.routeID].push 
            type: 'Feature'
            properties:
              'stroke-width': 6
            geometry: parseJSON path.geometry
            style: getStyle path.facilityT, path.routeID
            _length: path.length      

          previousRouteID = path.routeID
        
        routes.reverse()

        for route, routeID in routes
          _routeID = (routes.length - 1) - routeID
          totalLength = 0

          if startEdge?
            route.unshift 
              type: 'Feature'
              geometry: parseJSON startEdge.geometry
              style: getStyle startEdge.facilityT, _routeID

          if endEdge?
            route.push
              type: 'Feature'
              geometry: parseJSON endEdge.geometry
              style: getStyle endEdge.facilityT, _routeID

          for geometry in route
            layer = L.geoJson geometry, style: geometry.style
            totalLength += geometry._length if geometry._length?

            unless layers[_routeID]?
              layers[_routeID] = []

            layers[_routeID].push layer
            layerGroup.addLayer layer

          totalLength = (totalLength * 0.00018939).toFixed(4)
          
          if totalLength > 1
            totalLength = "#{totalLength} miles"
          else
            totalLength = "#{totalLength} mile"

          $ "div.result:eq(#{_routeID}) span.length"
            .html totalLength

        drawLine [startPoint.lng, startPoint.lat], getConnectionPoint routes[0][0], routes[0][1]
        drawLine [endPoint.lng, endPoint.lat], getConnectionPoint routes[0][routes[0].length - 1], routes[0][routes[0].length - 2]

        _this.prop 'disabled', false

        $ 'div.results'
          .removeClass 'hidden'
      catch e        
        showAlert 'Something went wrong. Please reload the page and try again.'

        console.log e

      return

    return
