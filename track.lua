--
-- Functions to manipulate tracks 
--
  
require( 'geo' )
require( 'bspline' )

local rotatedMarks = {}

--- Calculate a headland track inside polygon in offset distance
function calculateHeadlandTrack( polygon, offset )
  local track = {}
  for i, point in ipairs( polygon ) do
    -- get a point perpendicular to the current point in offset distance
    local newPoint = addPolarVectorToPoint( point, point.tangent.angle + getInwardDirection( polygon.isClockwise ), offset )
    table.insert( track, { x = newPoint.x, y = newPoint.y })
  end
  calculatePolygonData( track )
  removeLoops( track, 20 )
  removeLoops( track, 20 )
  applyLowPassFilter( track, math.deg( 120 ), 4.1 )
  track = smooth( track, 1 )
  -- don't filter for angle, only distance
  applyLowPassFilter( track, 2 * math.pi, 3 )
  track.boundingBox = getBoundingBox( track )
  return track
end

--- Link the generated, parallel circular headland tracks to
-- a single spiral track
-- First, We have to find where to start our course. 
--  If we work on the headland first:
--  - the starting point will be on the outermost headland track
--    close to the current vehicle position. The vehicle's heading 
--    is used to decide the direction, clockwise or counterclockwise
--  - for the subsequent headland passes, we add a 90 degree vector 
--    to the first point of the first pass and then continue from there
--    inwards
--
function linkHeadlandTracks( field, implementWidth )
  -- first, find the intersection of the outermost headland track and the 
  -- vehicles heading vector. 
  local startLocation = field.vehicle.location
  local heading = math.rad( field.vehicle.heading )
  local distance = maxDistanceFromField 
  local headlandPath = {}
  vectors = {}
  for i = 1, #field.headlandTracks do
    table.insert( vectors, { startLocation, addPolarVectorToPoint( startLocation, heading, distance )})
    local fromIndex, toIndex = getIntersectionOfLineAndPolygon( field.headlandTracks[ i ], startLocation, 
                               addPolarVectorToPoint( startLocation, heading, distance ))
    print( "Pass #" .. i, fromIndex, toIndex, startLocation.x, startLocation.y,  math.deg( heading ))
    if fromIndex then
      -- now find out which direction we have to drive on the headland pass.
      -- This depends on the order of the points in the polygon: clockwise or 
      -- counterclockwise. Basically we have to know if we follow the points
      -- of the polygon in increasing or decreasing index order. So, if 
      -- fromIndex (the smaller one) is closer to us, we need to follow
      -- the points as they defined in the polygon. Otherwise it is the 
      -- reverse order.
      local distanceFromFromIndex = getDistanceBetweenPoints( field.headlandTracks[ i ][ fromIndex ], field.vehicle.location )
      local distanceFromToIndex = getDistanceBetweenPoints( field.headlandTracks[ i ][ toIndex ], field.vehicle.location )
      if distanceFromToIndex < distanceFromFromIndex then
        -- must reverse direction
        print( "Reversing headland track" )
        -- driving direction is in decreasing index, so we start at fromIndex and go a full circle
        -- to toIndex 
        addTrackToHeadlandPath( headlandPath, field.headlandTracks[ i ], 1, fromIndex, toIndex, -1 )
        print( math.deg( field.headlandTracks[ i ][ toIndex ].tangent.angle ), math.deg( heading ))
        startLocation = field.headlandTracks[ i ][ fromIndex ]
        field.headlandTracks[ i ].circleStart = fromIndex
        field.headlandTracks[ i ].circleEnd = toIndex 
        field.headlandTracks[ i ].circleStep = -1
      else
        -- driving direction is in increasing index, so we start at toIndex and go a full circle
        -- back to fromIndex
        addTrackToHeadlandPath( headlandPath, field.headlandTracks[ i ], 1, toIndex, fromIndex, 1 )
        startLocation = field.headlandTracks[ i ][ toIndex ]
        field.headlandTracks[ i ].circleStart = toIndex
        field.headlandTracks[ i ].circleEnd = fromIndex 
        field.headlandTracks[ i ].circleStep = 1
      end
      v = { location = startLocation, heading=math.deg( heading ) }
      -- remember this, we'll need when generating the link from the last headland pass
      -- to the parallel tracks
      table.insert( marks, field.headlandTracks[ i ][ fromIndex ])
      table.insert( marks, field.headlandTracks[ i ][ toIndex ])
      field.headlandPath = headlandPath
    end
  end
end

--- add a series of points (track) to the headland path. This is to 
-- assemble the complete spiral headland path from the individual 
-- parallel headland tracks.
function addTrackToHeadlandPath( headlandPath, track, passNumber, from, to, step)
  for i, point in polygonIterator( track, from, to, step ) do
    table.insert( headlandPath, track[ i ])
    headlandPath[ #headlandPath ].passNumber = passNumber
  end
end
--- Find the best angle to use for the tracks in a field.
--  The best angle results in the minimum number of tracks
--  (and thus, turns) needed to cover the field.
function findBestTrackAngle( field, width )
  local minTracks = 10000
  local bestAngle = nil
  for angle = 0, 180, 1 do
    local rotated = rotatePoints( field, math.rad( angle ))
    --local nTracks = ( rotated.boundingBox.maxY - rotated.boundingBox.minY ) / width
    local tracks = generateParallelTracks( rotated, width )
    local nTracks, nSplitTracks = countTracks( tracks )
    if nTracks < minTracks and ( enableSplitTracks or nSplitTracks == 0 ) then
      minTracks = nTracks
      bestAngle = angle
    end
  end
  if bestAngle then 
    print( "Best angle: " .. bestAngle .. " tracks: " .. minTracks )
  end
  return bestAngle
end

--- Generate up/down tracks covering a field at the optimum angle
function generateTracks( field, width )
  -- translate field so we can rotate it around its center. This way all points
  -- will be approximately the same distance from the origo and the rotation calculation
  -- will be more precise
  local bb = getBoundingBox( field )
  local dx, dy = ( bb.maxX + bb.minX ) / 2, ( bb.maxY + bb.minY ) / 2 
  local translated = translatePoints( field, -dx , -dy )
  -- Now, determine the angle where the number of tracks is the minimum
  local bestAngle = findBestTrackAngle( translated, width )
  if not bestAngle then
    bestAngle = field.bestDirection.dir
    print( "No best angle found, use the longest edge direction " .. bestAngle )
  end
  -- now, generate the tracks according to the implement width within the rotated field's bounding box
  -- using the best angle
  local rotated = rotatePoints( translated, math.rad( bestAngle ))
  local parallelTracks = generateParallelTracks( rotated, width )

  table.insert( rotatedMarks, rotated.bottomIntersections[ 1 ].point )
  table.insert( rotatedMarks, rotated.bottomIntersections[ 2 ].point )
  table.insert( rotatedMarks, rotated.topIntersections[ 1 ].point )
  table.insert( rotatedMarks, rotated.topIntersections[ 2 ].point )
  
  addWaypointsToTracks( parallelTracks, width )
  -- Now we have the waypoints for each track, going from left to right
  -- Next, find out where to start: bottom left, bottom rigth, top left or top right
  -- whichever is closer to the end of the headland track.
  -- So start walking on the headland track until we bump on to one of those corners.
  local bottomToTop, leftToRight = findStartOfParallelTracks( rotated, field.circleStart, field.circleEnd, field.circleStep, parallelTracks )
  local track = generateWaypointsForParallelTracks( parallelTracks, bottomToTop, leftToRight ) 
  
  -- now rotate and translate everything back to the original coordinate system
  rotatedMarks = translatePoints( rotatePoints( rotatedMarks, -math.rad( bestAngle )), dx, dy )
  for i = 1, #rotatedMarks do
    table.insert( marks, rotatedMarks[ i ])
  end
  return translatePoints( rotatePoints( track, -math.rad( bestAngle )), dx, dy )
end

----------------------------------------------------------------------------------
-- Functions below work on a field rotated so that all parallel tracks are 
-- horizontal ( y = constant ). This makes track calculation really easy.
----------------------------------------------------------------------------------


--- Generate a list of parallel tracks within the field's boundary
-- At this point, tracks are defined only by they endpoints and 
-- are not connected
function generateParallelTracks( field, width )
  local tracks = {}
  local trackIndex = 1
  for y = field.boundingBox.minY + width / 2, field.boundingBox.maxY, width do
    local from = { x = field.boundingBox.minX, y = y, track=trackIndex }
    local to = { x = field.boundingBox.maxX, y = y, track=trackIndex }
    -- for now, all tracks go from min to max, we'll take care of
    -- alternating directions later.
    table.insert( tracks, { from=from, to=to, intersections={}} )
    trackIndex = trackIndex + 1
  end
  -- tracks has now a list of segments covering the bounding box of the 
  -- field. 
  findTrackEnds( field, tracks )
  return tracks
end

--- Input is a field boundary (like the innermost headland track) and 
--  a list of segments. The segments represent the parallel tracks. 
--  This function finds the intersections with the the field
--  boundary.
function findTrackEnds( field, tracks )
  local ix = function( a ) return getPolygonIndex( field, a ) end
  field.bottomIntersections = {}
  field.topIntersections = {}
  -- loop through the polygon and check each vector from 
  -- the current point to the next
  for i, cp in ipairs( field ) do
    local np = field[ ix( i + 1 )] 
    for j, t in ipairs( tracks ) do
      local is = getIntersection( cp.x, cp.y, np.x, np.y, t.from.x, t.from.y, t.to.x, t.to.y ) 
      if is then
        -- the line between from and to (the track) intersects the vector from cp to np
        table.insert( t.intersections, is )
        -- Remember the intersections with the first and the last track. 
        -- This is were we will want to transition from the headland to the center
        -- parallel tracks
        if j == 1 then
          -- bottommost track
          table.insert( field.bottomIntersections, { index=i, point=is })
        end
        if j == #tracks then
          -- topmost track
          table.insert( field.topIntersections, { index=i, point=is })
        end
      end
    end
  end
end

--- convert a list of tracks to waypoints, also cutting off
-- the part of the track which is outside of the field.
--
-- use the fact that at this point the field and the tracks
-- are rotated so that the tracks are parallel to the x axle and 
-- the first track has the lowest y coordinate
--
-- Also, we expect the tracks already have the intersection points with
-- the field boundary and there are exactly two intersection points
function addWaypointsToTracks( tracks, width )
  local track = {}
  for i = 1, #tracks do
    if #tracks[ i ].intersections > 1 then
      local newFrom = math.min( tracks[ i ].intersections[ 1 ].x, tracks[ i ].intersections[ 2 ].x ) + width / 2
      local newTo = math.max( tracks[ i ].intersections[ 1 ].x, tracks[ i ].intersections[ 2 ].x ) - width / 2
      -- if a track is very short (shorter than width) we may end up with newTo being
      -- less than newFrom. Just skip that track
      if newTo > newFrom then
        tracks[ i ].waypoints = {}
        for x = newFrom, newTo, waypointDistance do
          table.insert( tracks[ i ].waypoints, { x=x, y=tracks[ i ].from.y, track=i })
          table.insert( track, tracks[ i ].waypoints[ #tracks[ i ].waypoints ])
        end
        -- make sure we actually reached newTo, if waypointDistance is too big we may end up 
        -- well before the innermost headland track or field boundary
        if newTo - tracks[ i ].waypoints[ #tracks[ i ].waypoints ].x > waypointDistance * 0.25 then
          table.insert( tracks[ i ].waypoints, { x=newTo, y=tracks[ i ].from.y, track=i })
          table.insert( track, tracks[ i ].waypoints[ #tracks[ i ].waypoints ])
        end
      end
    end
  end
  return track
end 

function findStartOfParallelTracks( field, from, to, step, tracks )
  -- field.toIndex is the last point of the headland path
  -- the point with the smallest x is on the left
  local bottomLeftIx, bottomRightIx, topLeftIx, topRightIx
  if field.bottomIntersections[ 2 ].point.x >= field.bottomIntersections[ 1 ].point.x then
    bottomLeftIx = field.bottomIntersections[ 1 ].index
    bottomRightIx = field.bottomIntersections[ 2 ].index
  else
    bottomLeftIx = field.bottomIntersections[ 2 ].index
    bottomRightIx = field.bottomIntersections[ 1 ].index
  end
  if field.topIntersections[ 2 ].point.x >= field.topIntersections[ 1 ].point.x then
    topLeftIx = field.topIntersections[ 1 ].index
    topRightIx = field.topIntersections[ 2 ].index
  else
    topLeftIx = field.topIntersections[ 2 ].index
    topRightIx = field.topIntersections[ 1 ].index
  end
  print( bottomLeftIx, bottomRightIx, topLeftIx, topRightIx )
  for i in polygonIterator( field, from, to, step ) do
    print( i )
    if i == bottomLeftIx then
      print( "Starting at bottom left" )
      return true, true
    elseif i == bottomRightIx then
      print( "Starting at bottom right" )
      return true, false
    elseif i == topLeftIx then 
      print( "Starting at top left" )
      return false, true
    elseif i == topRightIx then
      print( "Starting at top right" )
      return false, false
    end
  end
  print( "Start not found, starting at bottom left" )
  return true, true
end

--- generate waypoints for the parallel tracks in the center of the field.
-- if bottomToTop == true then start at the bottom and work our way up
-- if leftToRight == true then start the first track on the left 
function generateWaypointsForParallelTracks( parallelTracks, bottomToTop, leftToRight ) 
  local track = {}
  local startTrack, endTrack, trackStep
  if bottomToTop then
    startTrack = 1
    endTrack = #parallelTracks
    trackStep = 1
  else
    startTrack = #parallelTracks
    endTrack = 1
    trackStep = -1
  end
  local evenOrOdd
  if leftToRight then
    -- every odd track is in the normal direction
    evenOrOdd = 0
  else
    evenOrOdd = 1
  end
  print( bottomToTop, leftToRight )
  local nTrack = 1
  for i = startTrack, endTrack, trackStep do
    -- every second track is in the other direction
    if nTrack % 2 == evenOrOdd then
      parallelTracks[ i ].waypoints = reverse( parallelTracks[ i ].waypoints)
    end
    for j, point in ipairs( parallelTracks[ i ].waypoints) do
      table.insert( track, point )
    end      
    nTrack = nTrack + 1
  end
  return track
end

--- count tracks based on their intersection with a field boundary
-- if there are two intersections, it is one track
-- if there are four, it is actually two tracks because of a concave field 
function countTracks( tracks )
  local nTracks = 0
  -- tracks intersecting a concave field boundary
  local nSplitTracks = 0 
  for j, t in ipairs( tracks ) do
    nTracks = nTracks +  #t.intersections / 2
    if #t.intersections > 2 then 
      nSplitTracks = nSplitTracks + 1
    end
  end
  return nTracks, nSplitTracks
end

