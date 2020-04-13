ruleset alexyancey.github.io.twilio_v2 {
  meta {
    configure using account_sid = ""
                    auth_token = ""
    provides
        send_sms, messages
  }

  global {
    send_sms = defaction(to, from, message) {
       base_url = <<https://#{account_sid}:#{auth_token}@api.twilio.com/2010-04-01/Accounts/#{account_sid}/>>
       http:post(base_url + "Messages.json", form = {
                "From":from,
                "To":to,
                "Body":message
            })
    }

    messages = function(to, from, size) {
      base_url = <<https://#{account_sid}:#{auth_token}@api.twilio.com/2010-04-01/Accounts/#{account_sid}/>>

      //Optional parameters for filtering purposes
      query = {}
      query = (size == "" || size.isnull()) => query | query.put({"PageSize": size})
      query = (to == "" || to.isnull()) => query | query.put({"To": to})
      query = (from == "" || from.isnull()) => query | query.put({"From": from})

      res = http:get(base_url + "Messages.json", qs = query)
      //Decode the response and only send the 'messages' portion
      return res{"content"}.decode()
    }
  }
}
