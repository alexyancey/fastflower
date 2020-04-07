ruleset twilioApiModule {
  meta {
    configure using account_sid = ""
                    auth_token = ""
    provides send_sms, messages
  }
 
  global {
    base_url = <<https://#{account_sid}:#{auth_token}@api.twilio.com/2010-04-01/Accounts/#{account_sid}/>>

    send_sms = defaction(to, from, message) {
       http:post(base_url + "Messages.json", form = {
                "From":from,
                "To":to,
                "Body":message
            })
    }
    messages = function(to, from, paginated) {
      items = http:get(base_url + "Messages.json", form = {
        "From":from,
        "To":to,
      }, qs = query){"content"}.decode().klog()
      return items
    }
  }
}