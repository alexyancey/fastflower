ruleset flower_shop {
  meta {

  }
  global {
    getLocation = function() {
      return ent:location.defaultsTo("placeholderLocation")
    }
    getDriverEci = function() {
      return ent:driverEci
    }
  }

  rule new_delivery_request {
    select when shop delivery

    pre {
      location = getLocation()
      customerName = event:attr("customerName")
      address = event:attr("address")
      decisionTime = event:attr("decisionTime")
      driverEci = getDriverEci()
    }
    event:send({
      "eci": driverEci,
      "domain": driver,
      "type": 
    })

  }



}