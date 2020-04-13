ruleset driver {
  meta {
        use module io.picolabs.subscription alias Subscriptions
        shares __testing, getOrders
    }

    global {
        __testing = { "queries": [ { "name": "getOrders" } ],
                      "events":  [ { "domain": "driver", "type": "set_sms", "attrs": [ "sms" ] },
                                   { "domain": "driver", "type": "set_location", "attrs": [ "lat", "lng" ] },
                                   { "domain": "driver", "type": "bid_order", "attrs": [ "orderId" ] },
                                   { "domain": "driver", "type": "new_rating", "attrs": [ "rating" ] },
                                   { "domain": "driver", "type": "delivery_complete", "attrs": [ "rating" ] } ] }

        default_rating = 3
        default_ratings = [3]
        default_sms = "+12063848336"

        getOrders = function() {
          ent:seen_orders
        }

        getSequence = function(orderId) {
            orderId.split(re#:#)[1].as("Number")
        }

        getID = function(orderId) {
            orderId.split(re#:#)[0]
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
                id = getID(a{"orderId"});
                id == picoId
            }).map(function(a) {
                getSequence(a{"orderId"})
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
                id = getID(a{"orderId"});
                return seen{id}.isnull() || (seen{id} < getSequence(a{"orderId"})) => true | false;
            }).sort(function(a, b) {
                getSequence(a{"orderId"}) < getSequence(b{"orderId"})  => -1 |
                getSequence(a{"orderId"}) == getSequence(b{"orderId"}) =>  0 |
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
        "orderId": <storeEci:sequence>,
        "customerId": <customer name>,
        "customerLocation": <Lat, Lng>,
        "storeEci": _____
    }
    */


    rule new_order {
        select when driver new_order

        pre {
            //Get order from store
            order = event:attr("order").klog("New Order: ")
            orderId = order{"orderId"}

        }

        always {
            ent:seen_orders := ent:seen_orders.append(order)
            ent:seen{orderId} := consecutiveSequence(orderId)
        }
    }

    rule bid_order {
        select when driver bid_order

        pre {
          orderId = event:attr("orderId")
          store_eci = ent:seen_orders.filter(function(a) {
            a{"orderId"} == orderId
          })[0]{"storeEci"}

          driver_eci = meta:eci
          driver_location = ent:location
          driver_sms = ent:sms
          driver_rating = ent:rating
        }
        /*
        Send back to store:
        {
            "driverEci": ______,
            "driverLocation": _____,
            "driverSms": ______,
            "driverRating": ______
        }
        */

        event:send({
            "eci": store_eci,
            "domain": "store", "type": "driver_bid",
            "attrs": {
              "driverEci": driver_eci,
              "driverLocation": driver_location,
              "driverSms": driver_sms,
              "driverRating": driver_rating,
              "orderId": orderId
            }
        })
    }

    rule bid_accepted {
        select when driver bid_accepted

        always {
          ent:current_order := event:attr("order").klog("Your Current Order: ")
        }
    }

    rule delivery_complete {
        select when driver delivery_complete

        pre {
            driver_eci = meta:eci
            customer_location = ent:current_order{"customerLocation"}
            driver_sms = ent:sms
            rating = event:attr("rating").as("Number")
        }

        always {
          ent:total_ratings := ent:total_ratings.append(rating)
          ent:rating := ent:total_ratings.reduce(function(a, b) {a + b}) / ent:total_ratings.length()
          ent:location := customer_location

          raise driver event "inform_store"
        }
    }

    rule inform_store {
      select when driver inform_store

      //Raise event to store indicating the order was completed
      event:send({
        "eci": ent:current_order{"storeEci"},
        "eid": "fastflower",
        "domain": "store", "type": "delivery_complete",
        "attrs": {
          "orderId": ent:current_order{"orderId"}
        }
      })

      always {
        ent:current_order := {}
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

            //40.567257,-111.838092
            rand_lat = random:number(lower = 40.567200, upper = 40.567500).as("String")
            rand_lat = rand_lat.substr(0, 9)

            rand_lng = random:number(lower = -111.838000, upper = -111.838500).as("String")
            rand_lng = rand_lng.substr(0, 11)

            start_location = { "lat": rand_lat, "lng": rand_lng }
            ent:location := start_location

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
            orderId = message{"orderId"}
        }

        event:send({
            "eci": subscriber{"Tx"},
            "eid": "driver_message",
            "domain": "driver", "type": "seen",
            "attrs": {"message": message, "sender": {"picoId": orderId, "Rx": subscriber{"Rx"}}}
        })
    }

    rule driver_send_rumor {
        select when driver send_rumor

        pre {
            subscriber = event:attr("subscriber")
            message = event:attr("message")
            picoId = getID(message{"orderId"})
            sequence = getSequence(message{"orderId"})
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
            id = event:attr("orderId")
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
                "orderId": id,
                "customerId": event:attr("customerId"),
                "customerLocation": event:attr("customerLocation"),
                "storeEci": event:attr("storeEci")})
            if ent:seen_orders.filter(function(a) {a{"orderId"} == id}).length() == 0

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
