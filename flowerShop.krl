ruleset flower_store {
  meta {
    use module twilio_auth
    use module twilioApiModule alias TwilioApi
    with account_sid = keys:auth{"account_sid"}
         auth_token =  keys:auth{"auth_token"}
  }
  global {
    getStoreLocation = function() {
      return ent:storeLocation.defaultsTo("placeholderLocation")
    }
    getknownDriverEci = function() {
      return ent:knownDriverEci
    }
    getorderId = function() {
      return {}.put(meta:picoId, ent:orderId)
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
    getRatingThreshold = function() {
      return ent:ratingThreshold.defaultsTo(2)
    }
    getAutoAssignDrivers = function() {
      return ent:autoAssignDrivers.defaultsTo(true)
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
      schedule store event ((getAutoAssignDrivers() == true) => "select_driver" | "") at time:add(time:now(), {"seconds": getDecisionTime()})
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
    select when store select_driver
    foreach getOrderBids(event:attr("orderId")) setting (bid)
    //decide which driver should get the bid
    pre {
      currentWinner = getWinningDriver(event:attr("orderId")).defaultsTo(bid)
      distanceWinner = ((currentWinner{"distance"} < bid{"distance"}) => currentWinner | bid)
      newWinner = ((bid{"driverRating"}.as("Number") < getRatingThreshold()) => currentWinner | distanceWinner)
    }
    noop()
    fired {
      ent:currentWinner := ent:currentWinner.put([event:attr("orderId")], newWinner)
      raise event notify_driver 
      attributes event:attr() on final
    }
  }

  rule manual_select_driver {
    select when store manual_select_driver
    pre {
      newWinner = getOrderBids(event:attr("orderId")).filter(function(a) {
        a{"driverEci"} == event:attr("driverEci")
      })
    }
    noop()
    fired {
      ent:currentWinner := ent:currentWinner.put([event:attr("orderId")], newWinner)
      raise event notify_driver 
      attributes event:attr() on final
    }
  }

  rule notify_driver {
    select when store notify_driver

    pre {
      winningDriver = getWinningDriver(event:attr("orderId"))
    }
    if (winningDriver) then 
    every {
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
      TwilioApi:send_sms(sensor:receiving_phone(), sensor:sending_phone(), "Temperature on your wovyn device is above your threshold of " + sensor:temperature_threshold())
    }
  }

  rule set_properties {
    select when store set_properties
    pre {
      driverEci = event:attr("driverEci").defaultsTo(getdriverEci())
      storeLocation = event:attr("location").defaultsTo(getStoreLocation())
      decisionTime = event:attr("decisionTime").defaultsTo(getDecisionTime())
      ratingThreshold = event:attr("ratingThreshold").defaultsTo(getRatingThreshold())
      autoAssignDrivers = event:attr("autoAssignDrivers").defaultsTo(getAutoAssignDrivers())
      orderId = 0.defaultsTo(getorderId())
    }
    noop()
    fired {
      ent:driverEci := driverEci
      ent:storeLocation := storeLocation
      ent:orderId := orderId
      ent:decisionTime := decisionTime
      ent:ratingThreshold := ratingThreshold
      ent:autoAssignDrivers := autoAssignDrivers
    }
  }

}