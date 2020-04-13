ruleset use_bingMapApiModule {
  meta {
    configure using api_key = ""
    provides
        getDistanceOfPoints
  }

  global {
    getDistanceOfPoints = function(srcLat, srcLong, destLat, destLong) {
      response = http:get(<<https://dev.virtualearth.net/REST/v1/Routes/DistanceMatrix?origins=#{srcLat},#{srcLong}&destinations=#{destLat},#{destLong}&travelMode=driving&key=#{api_key}>>)
      response = response{"content"}.decode()
      result = response{"resourceSets"}[0]{"resources"}[0]{"results"}[0]
      return {"distance": result{"travelDistance"}, "duration": result{"travelDuration"}}
    }
  }
}
