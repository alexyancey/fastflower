ruleset flower_shop {
  meta {

  }
  global {
    getStoreLocation = function() {
      return ent:storeLocation.defaultsTo("placeholderLocation")
    }
    getDriverEci = function() {
      return ent:driverEci
    }
  }

  rule new_delivery_request {
    select when shop order

    pre {
      storeLocation = getStoreLocation()
      customerName = event:attr("customerName")
      customerLocation = event:attr("customerLocation")
      decisionTime = event:attr("decisionTime")
      driverEci = getDriverEci()
    }
    event:send({
      "eci": driverEci,
      "domain": driver,
      "type": "newJob",
      "attrs": {
        "decisionTime": decisionTime,
        "customerLocation": customerLocation,
        "customerName": customerName,
        "storeLocation": storeLocation
      }
    })

  }

  rule receive_order_report {
    select when shop orderReport
  }

  rule select_driver {
    select when shop selectDriver
  }


}