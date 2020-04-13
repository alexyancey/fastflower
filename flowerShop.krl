ruleset flower_store {
  meta {
    use module alexyancey.github.io.keys
    use module alexyancey.github.io.twilio_v2 alias twilio
        with account_sid = keys:twilio{"account_sid"}
             auth_token =  keys:twilio{"auth_token"}
    use module bingMapApiModule
    use module use_bingMapApiModule alias bing
        with api_key = keys:auth{"api_key"}
    shares __testing, getDistanceOfPoints

  }
  global {
    __testing = { "queries": [ ],
                  "events":  [ { "domain": "store", "type": "set_properties", "attrs": [ "driverEci",
                                 "decisionTime", "ratingThreshold", "autoAssignDrivers" ] },
                               { "domain": "store", "type": "delivery_complete", "attrs" : [ "orderId" ] },
                               { "domain": "store", "type": "manual_select_driver", "attrs": [ "driverEci", "orderId" ] } ] }

    //knownDriverEci = "JtDf6BauFCevabgQYa91pK"

    getknownDriverEci = function() {
      return ent:driverEci
    }
    getorderId = function() {
      <<#{meta:picoId}:#{ent:orderId}>>
    }
    getDecisionTime = function() {
      return ent:decisionTime.defaultsTo(15)
    }
    getOrderBids = function(orderId) {
      return ent:bids{orderId}
    }
    getWinningDriver = function(orderId) {
      return ent:currentWinner{orderId}
    }
    getRatingThreshold = function() {
      return ent:ratingThreshold.defaultsTo(2)
    }
    getAutoAssignDrivers = function() {
      return ent:autoAssignDrivers.defaultsTo(true)
    }
    getDistanceOfPoints = function(srcLat, srcLong, destLat, destLong) {
      bing:getDistanceOfPoints(srcLat, srcLong, destLat, destLong)
    }
  }

  rule new_delivery_request {
    select when store order

    pre {
      customerName = event:attr("customerName")
      customerLocation = event:attr("customerLocation")
      knownDriverEci = getknownDriverEci()

      order = {
        "storeEci": meta:eci,
        "orderId": getorderId(),
        "customerId": customerName,
        "customerLocation": customerLocation
      }
    }

    event:send({
      "eci": getknownDriverEci(),
      "domain": "driver",
      "type": "new_order",
      "attrs": {
        "order": order
      }
    })

    always {
      schedule store event ((getAutoAssignDrivers() == true) => "select_driver" | "") at time:add(time:now(), {"seconds": getDecisionTime()})
      attributes {"order": order}
      ent:orders := ent:orders.append(order)
      ent:orderId := ent:orderId + 1
    }
  }

  rule receive_bid {
    select when store driver_bid
    pre {
      orderId = event:attr("orderId")
      bid = {
        "driverEci": event:attr("driverEci"),
        "driverLocation": event:attr("driverLocation"),
        "driverSms": event:attr("driverSms"),
        "driverRating": event:attr("driverRating")
      }.klog("New Bid: ")
    }
    noop()
    fired {
      ent:bids{orderId} := ent:bids{orderId}.append(bid)
    }
  }

  rule select_driver {
    select when store select_driver

    //decide which driver should get the bid
    pre {
      bids = getOrderBids(event:attr("order"){"orderId"}).klog("bids: ")
      order_location = event:attr("order"){"customerLocation"}
      filter_rating = bids.filter(function(a) {
        a{"driverRating"} > getRatingThreshold()
      }).klog("Filter Rating: ")
      sort_distance = filter_rating.sort(function(a, b) {
        time_a = getDistanceOfPoints(a{"driverLocation"}{"lat"}, a{"driverLocation"}{"lng"}, order_location{"lat"}, order_location{"lng"}){"duration"}
        time_b = getDistanceOfPoints(b{"driverLocation"}{"lat"}, b{"driverLocation"}{"lng"}, order_location{"lat"}, order_location{"lng"}){"duration"}
        time_a < time_b => -1 |
        time_a == time_b => 0 |
        1
      }).klog("Sort Distance: ")
      newWinner = sort_distance[0]
    }

    always {
      ent:currentWinner{event:attr("order"){"orderId"}} := newWinner
      raise store event "notify_driver" attributes event:attrs
    }
  }

  rule manual_select_driver {
    select when store manual_select_driver

    pre {
      newWinner = getOrderBids(event:attr("orderId")).filter(function(a) {
        a{"driverEci"} == event:attr("driverEci")
      })[0]

      order = ent:orders.filter(function(a) {
        a{"orderId"} == event:attr("orderId")
      })[0]
    }

    always {
      ent:currentWinner{event:attr("orderId")} := newWinner
      raise store event "notify_driver" attributes {"order": order}
    }
  }

  rule notify_driver {
    select when store notify_driver

    pre {
      order = event:attr("order"){"orderId"}.klog("ORDER: ")
      winningDriver = getWinningDriver(event:attr("order"){"orderId"}).klog("Winning Driver: ")
    }
    if (winningDriver) then
    every {
      event:send({
      "eci": winningDriver{"driverEci"},
      "domain": "driver",
      "type": "bid_accepted",
      "attrs": {
        "order": {
          "storeEci": meta:eci,
          "orderId": event:attr("order"){"orderId"},
          "customerId": event:attr("order"){"customerId"},
          "customerLocation": event:attr("order"){"customerLocation"}
          }
        }
      })
      twilio:send_sms(winningDriver{"driverSms"},
                      ent:store_sms,
                      <<Driver ID: #{winningDriver{"driverEci"}} you have been selected for Order ID: #{order}>>)
    }
  }

  rule delivery_complete {
    select when store delivery_complete

    pre {
      orderId = event:attr("orderId").klog("ORDER ID DONE: ")
    }

    //Delete bids for completed order
    always {
      ent:bids := ent:bids.delete([orderId])
    }
  }

  rule set_properties {
    select when store set_properties
    pre {
      driverEci = event:attr("driverEci").defaultsTo(getknownDriverEci())
      decisionTime = event:attr("decisionTime").as("Number").defaultsTo(getDecisionTime())
      ratingThreshold = event:attr("ratingThreshold").as("Number").defaultsTo(getRatingThreshold())
      autoAssignDrivers = event:attr("autoAssignDrivers").as("Boolean").defaultsTo(getAutoAssignDrivers())
      orderId = 0.defaultsTo(getorderId())
    }

    always {
      ent:driverEci := driverEci
      ent:orderId := orderId
      ent:decisionTime := decisionTime
      ent:ratingThreshold := ratingThreshold
      ent:autoAssignDrivers := autoAssignDrivers
      ent:currentWinner := {}
      ent:orders := []
      ent:store_sms := "+12056198458"
    }
  }

}
