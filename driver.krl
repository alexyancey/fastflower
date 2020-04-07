ruleset driver {
  meta {
        use module io.picolabs.subscription alias Subscriptions
        shares __testing
    }

    global {
        __testing = { "queries": [ ],
                      "events":  [ ] }

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


    /*
    Order format:
    {
        "OrderID": _____,
        "DriverID": _____,
        "CustomerID": ____,
        "CustomerAddress": ____,
        "StoreECI": _____,
    }
    */

    rule bid_order {
        select when driver bid_order

        /*
        Send back to store:
        {
            "DriverECI": ______,
            "DriverLocation": _____,
            "DriverSMS": ______,
            "DriverRating": ______
        }
        */
    }

    rule bid_accepted {
        select when driver bid_accepted

        //ent:current_order := event:attr("order")
    }

    rule bid_rejected {
        select when driver bid_rejected

        //ent:current_order := {}
    }

    rule delivery_complete {
        select when drive delivery_complete

        pre {
            timestamp = event:attr("timestamp")
            rating = event:attr("rating")
        }

        //raise event to store indicating the order was completed
    }

//----------------------------GOSSIP STUFF-----------------------------------------

    rule init {
        select when wrangler ruleset_added where rids >< meta:rid

        always {
            ent:interval := 3
            ent:sequence := 0
            ent:seen := {}
            ent:state := {}
            ent:seen_orders := []
            ent:current_order := {}
            ent:availability := "available"
            raise driver event "order_received"
        }
    }

    rule new_order {
        select when driver new_order

        pre {
            //Get order from store
            order = event:attr("order")
            orderID = event:attr("order"){"OrderID"}
        }
        always {
            ent:seen_orders := ent:seen_orders.append(order)
            ent:seen{orderID} := consecutiveSequence(orderID)
            ent:sequence := ent:sequence + 1
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
                "DriverID": event:attr("DriverID"),
                "CustomerID": event:attr("CustomerID"),
                "CustomerAddress": event:attr("CustomerAddress"),
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

    rule change_interval {
      select when driver change_interval

      pre {
        interval = event:attr("interval").defaultsTo(ent:interval)
      }

      always {
        ent:interval := interval
      }
    }
}
