# fastflower

# Workflow
1. Store receives order
2. Http event to one of the driver picos
- Customer name
- Customer address
- Schedule choose event for X seconds later
3. Driver accepts
- Driver info
- Channel ID
- Rating
4. Store receives event
- Pick first response OR
- Choose based off rating and location (Google Directions API)
- Send event to driver saying it was accepted
  - Channel ID of store
  - Twilio SMS to driver
5. Driver delivers flowers
- Send confirmation of completion to store
