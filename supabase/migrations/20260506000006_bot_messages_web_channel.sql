-- Allow web-bot Edge Function to log into bot_messages with channel='web'.
alter table bot_messages drop constraint if exists bot_messages_channel_check;
alter table bot_messages add constraint bot_messages_channel_check
  check (channel in ('sms','whatsapp','web'));
