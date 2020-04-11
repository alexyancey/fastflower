ruleset flower_store {
  meta {

  }
  global {
    getStoreLocation = function() {
      return ent:storeLocation.defaultsTo("placeholderLocation")
    }
    getknownDriverEci = function() {
      return ent:knownDriverEci
    }
    getorderId = function() {
      return meta:picoId + ent:orderId
    }
    getDecisionTime = function() {
      return ent:decisionTime.defaultsTo(15)
    }
    getOrderBids = function(orderId) {
      return ent:bids.filter(function(a) {
        a{"orderId"} == orderId
      })
    }
    getWinningDriver = function(orderId) {
      return ent:winningDriver{"orderId"}
    }
  }

  rule new_delivery_request {
    select when store order

    pre {
      storeLocation = getStoreLocation()
      customerName = event:attr("customerName")
      customerLocation = event:attr("customerLocation")
      decisionTime = event:attr("decisionTime")
      knownDriverEci = getKnownDriverEci()
    }
    event:send({
      "eci": knownDriverEci(),
      "domain": driver,
      "type": "new_order",
      "attrs": {
        "order": {
          "storeEci": meta:picoId,
          "orderId": getorderId(),
          "customerId": customerName,
          "customer_location": customerLocation
        },
        "storeLocation": storeLocation
      }
    })
    always {
      schedule store event "select_driver" at time:add(time:now(), {"seconds": ent:decisionTime})
        attributes {
          "orderId": getorderId(),
        }
        ent:orderId := ent:orderId + 1
    }
  }

  rule receive_bid {
    select when store driver_bid
    pre {
      bid = {
        "driverEci": event:attr("driverEci"),
        "driverLocation": event:attr("driverLocation"),
        "driverSms": event:attr("driverSms"),
        "driverRating": event:attr("driverRating")
      }
    }
    noop()
    fired {
      ent:bids := ent:bids.append(bid)
    }
  }

  rule select_driver {
    select when store selectDriver
    foreach getOrderBids(event:attr("orderId")) setting (bid)
    //decide which driver should get the bid
    pre {
      currentWinner = getWinningDriver(event:attr("orderId")).defaultsTo(bid)
      (currentWinner{"distance"} < bid{"distance"}) newWinner = currentWinner || bid
    }
    noop()
    fired {
      ent:currentWinner := ent:currentWinner.put([event:attr("orderId")], currentWinner)
      raise event notify_driver 
      attributes event:attr() on final
    }
  }

  rule notify_driver {
    select when store notify_driver

    pre {
      winningDriver = getWinningDriver(event:attr("orderId"))
    }
    event:send({
      "eci": winningDriver{"driverEci"},
      "domain": driver,
      "type": "bid_accepted",
      "attrs": {
        "order": {
          "storeEci": meta:picoId,
          "orderId": getorderId(),
          "customerId": customerName,
          "customer_location": customerLocation
        },
      }
    })
  }

  rule set_properties {
    select when store set_properties
    pre {
      driverEci = event:attr("driverEci").defaultsTo(getdriverEci())
      storeLocation = event:attr("location").defaultsTo(getStoreLocation())
      decisionTime = event:attr("decisionTime").defaultsTo(getDecisionTime())
      orderId = 0.defaultsTo(getorderId())
    }
    noop()
    fired {
      ent:driverEci := driverEci
      ent:storeLocation := storeLocation
      ent:orderId := orderId
      ent:decisionTime := decisionTime
    }
  }

}