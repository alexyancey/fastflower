ruleset driver {
  meta {
        use module io.picolabs.subscription alias Subscriptions
        shares __testing, getOrders
    }

    global {
        __testing = { "queries": [ { "name": "getOrders" } ],
                      "events":  [ { "domain": "driver", "type": "set_sms", "attrs": [ "sms" ] },
                                   { "domain": "driver", "type": "set_location", "attrs": [ "lat", "lng" ] },
                                   { "domain": "driver", "type": "bid_order", "attrs": [ "orderID" ] },
                                   { "domain": "driver", "type": "new_rating", "attrs": [ "rating" ] } ] }

        default_rating = 3
        default_ratings = [3]
        default_sms = "+12063848336"
        //40.567138, -111.838003
        default_location = { "lat": 40.567138, "lng": -111.838003 }

        getOrders = function() {
          ent:seen_orders
        }

        getSequence = function(OrderID) {
            OrderID.split(re#:#)[1].as("Number")
        }

        getID = function(OrderID) {
            OrderID.split(re#:#)[0]
        }

        getPeer = function() {
            //Pick a random peer node if no missing messages
            active_subscriptions = Subscriptions:established("Rx_role", "driver").klog("Subscriptions: ")
            rand_subscription = random:integer(active_subscriptions.length() - 1)

            peers = ent:state
            filtered = peers.filter(function(v,k){
                findMissing(v).length() > 0;
            })
            rand_filtered = random:integer(filtered.length() - 1)
            item = filtered.keys()[rand_filtered].klog("Node: ")

            search = active_subscriptions.filter(function(a) {a{"Tx"} == item})[0]
            search.isnull() => active_subscriptions[rand_subscription] | search
        }

        consecutiveSequence = function(picoId) {
            ent:seen_orders.filter(function(a) {
                id = getID(a{"OrderID"});
                id == picoId
            }).map(function(a) {
                getSequence(a{"OrderID"})
            }).sort(function(seq1, seq2) {
                seq1 < seq2  => -1 |
                seq1 == seq2 =>  0 |
                1
            }).reduce(function(seq1, seq2) {
                seq2 == seq1 + 1 => seq2 | seq1
            }, -1)
        }

        makeSeen = function() {
            return {
                "message_type": "seen",
                "message": ent:seen
            }
        }

        makeRumor = function(subscriber) {
            missing_msgs = findMissing(ent:state{subscriber{"Tx"}})
            return {
                "message_type": "rumor",
                "message": missing_msgs.length() == 0 => null | missing_msgs[0]
            }
        }

        findMissing = function(seen) {
            ent:seen_orders.filter(function(a) {
                id = getID(a{"OrderID"});
                return seen{id}.isnull() || (seen{id} < getSequence(a{"OrderID"})) => true | false;
            }).sort(function(a, b) {
                getSequence(a{"OrderID"}) < getSequence(b{"OrderID"})  => -1 |
                getSequence(a{"OrderID"}) == getSequence(b{"OrderID"}) =>  0 |
                1
            })
        }

        prepareMessage = function(subscriber) {
            //Randomly pick message type
            rand_message = random:integer(1);
            return (rand_message == 0) => makeRumor(subscriber) | makeSeen()
        }
    }

//------------------------NEEDED BY STORES---------------------------------------------

    /*
    Order format:
    {
        "OrderID": <StoreECI:sequence>,
        "CustomerID": <customer name>,
        "CustomerLocation": <Lat, Lng>,
        "StoreECI": _____
    }
    */


    rule new_order {
        select when driver new_order

        pre {
            //Get order from store
            order = event:attr("order")
            orderID = order{"OrderID"}

        }

        always {
            ent:seen_orders := ent:seen_orders.append(order)
            ent:seen{orderID} := consecutiveSequence(orderID)
        }
    }

    rule bid_order {
        select when driver bid_order

        pre {
          orderID = event:attr("orderID")
          store_eci = ent:seen_orders.filter(function(a) {
            a{"OrderID"} == orderID
          })[0]{"StoreECI"}.klog("Chosen Store: ")

          driver_eci = meta:picoId
          driver_location = ent:location
          driver_sms = ent:sms
          driver_rating = ent:rating
        }
        /*
        Send back to store:
        {
            "DriverECI": ______,
            "DriverLocation": _____,
            "DriverSMS": ______,
            "DriverRating": ______
        }
        */

        /*event:send({
            "eci": store_eci,
            "eid": "fastflower",
            "domain": "store", "type": "driver_bid",
            "attrs": {
              "DriverECI": driver_eci,
              "DriverLocation": driver_location,
              "DriverSMS": driver_sms,
              "DriverRating": driver_rating
            }
        })*/
    }

    rule bid_accepted {
        select when driver bid_accepted

        always {
          ent:current_order := event:attr("order")
        }
    }

    rule delivery_complete {
        select when driver delivery_complete

        pre {
            driver_eci = meta:picoId
            customer_location = current_order{"CustomerLocation"}
            driver_sms = ent:sms
            rating = event:attr("rating")
        }

        always {
          ent:total_ratings := ent:total_ratings.append(rating)
          ent:rating := ent:total_ratings.reduce(function(a, b) {a + b}) / ent:total_ratings.length()
          ent:location := customer_location

          //Raise event to store indicating the order was completed
          /*event:send({
            "eci": ent:current_order{"StoreECI"},
            "eid": "fastflower",
            "domain": "store", "type": "delivery_complete",
            "attrs": {
              "DriverECI": driver_eci,
              "DriverLocation": ent:location,
              "DriverSMS": driver_sms,
              "DriverRating": ent:rating
            }
        })*/
        }
    }

//-------------------------------END----------------------------------------------

//----------------------------GOSSIP STUFF-----------------------------------------

    rule init {
        select when wrangler ruleset_added where rids >< meta:rid

        always {
            ent:interval := 3
            ent:seen := {}
            ent:state := {}
            ent:seen_orders := []
            ent:current_order := {}
            ent:availability := "available"
            ent:sms := default_sms
            //40.567138, -111.838003
            ent:location := default_location
            ent:rating := default_rating
            ent:total_ratings := default_ratings
            raise driver event "order_received"
        }
    }

    rule driver_order_received {
        select when driver order_received where ent:availability == "available"

        pre {
            subscriber = getPeer()
            m = prepareMessage(subscriber)
        }

        if (not subscriber.isnull()) && (not m{"message"}.isnull()) then noop()
        fired {
            raise driver event "send_rumor" attributes {"subscriber": subscriber, "message": m{"message"}} if (m{"message_type"} == "rumor")
            raise driver event "send_seen" attributes {"subscriber": subscriber, "message": m{"message"}} if (m{"message_type"} == "seen")
        }
    }

    rule driver_schedule {
        select when driver order_received

        always {
            schedule driver event "order_received" at time:add(time:now(), {"seconds": ent:interval})
        }
    }

    rule driver_send_seen {
        select when driver send_seen

        pre {
            subscriber = event:attr("subscriber")
            message = event:attr("message")
            orderID = message{"OrderID"}
        }

        event:send({
            "eci": subscriber{"Tx"},
            "eid": "driver_message",
            "domain": "driver", "type": "seen",
            "attrs": {"message": message, "sender": {"picoId": orderID, "Rx": subscriber{"Rx"}}}
        })
    }

    rule driver_send_rumor {
        select when driver send_rumor

        pre {
            subscriber = event:attr("subscriber")
            message = event:attr("message")
            picoId = getID(message{"OrderID"})
            sequence = getSequence(message{"OrderID"})
        }

        event:send({
            "eci": subscriber{"Tx"},
            "eid": "driver_message",
            "domain": "driver", "type": "rumor",
            "attrs": message
        })

        always {
            ent:state{subscriber{"Tx"}{picoId}} := sequence
            if (ent:state{subscriber{"Tx"}}{picoId} + 1 == sequence) || (ent:state{subscriber{"Tx"}}{picoId}.isnull() && sequence == 0)
        }
    }

    rule driver_rumor {
        select when driver rumor

        pre {
            id = event:attr("OrderID")
            seq_num = getSequence(id)
            pico_id = getID(id)
            seen_obj = ent:seen{pico_id}
            first = ent:seen{pico_id}.isnull()
        }

        if first then noop()
        fired {
            ent:seen{pico_id} := -1
        } finally {
            ent:seen_orders := ent:seen_orders.append({
                "OrderID": id,
                "CustomerID": event:attr("CustomerID"),
                "CustomerLocation": event:attr("CustomerLocation"),
                "StoreECI": event:attr("StoreECI")})
            if ent:seen_orders.filter(function(a) {a{"OrderID"} == id}).length() == 0

            ent:seen{pico_id} := consecutiveSequence(pico_id)
        }
    }

    rule driver_seen {
        select when driver seen

        foreach findMissing(event:attr("message")) setting(messages)
        pre {
            sender_rx = event:attr("sender"){"Rx"}
            sender_id = event:attr("sender"){"picoID"}
            message = event:attr("message")
        }

        event:send({
          "eci": sender_rx,
          "eid": "response",
          "domain": "driver", "type": "rumor",
          "attrs": messages
        })

        always {
            ent:state{sender_rx} := message
        }
    }

    rule toggle_availability {
      select when driver toggle_availability

      pre {
        availability = event:attr("availability").defaultsTo(ent:availability)
      }

      always {
        ent:availability := availability
      }
    }

    rule set_sms {
      select when driver set_sms

      pre {
        sms = event:attr("sms").defaultsTo(ent:sms)
      }

      always {
        ent:sms := sms
      }
    }

    rule set_location {
      select when driver set_location

      pre {
        lat = event:attr("lat")
        lng = event:attr("lng")
      }

      always {
        ent:location := { "lat": lat, "lng": lng }
      }
    }

    rule new_rating {
      select when driver new_rating

      pre {
        rating = event:attr("rating").as("Number")
      }

      always {
        ent:total_ratings := ent:total_ratings.append(rating)
        ent:rating := ent:total_ratings.reduce(function(a, b) {a + b}) / ent:total_ratings.length()
      }
    }
}
