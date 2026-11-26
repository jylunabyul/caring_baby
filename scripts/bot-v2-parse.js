// Embedded in the n8n Code node by build-bot-v2.mjs. No network or credentials.
const update = $json;
const cb = update.callback_query;
const message = cb?.message || update.message;
const sender = cb?.from || message?.from;
if (!message || message.chat?.type !== 'private' || String(message.chat.id) !== '9114513581' || String(sender?.id) !== '9114513581') return [];
let action = 'unknown', args = {};
const text = (message.text || '').trim();
let m;
if (cb) {
  const data = cb.data || '';
  if (data === 'cancel') action = 'cancel';
  else if ((m = data.match(/^(fed|later):([0-9a-f-]{36})$/i))) {
    action = m[1]; args = {child_id:m[2]};
  } else if ((m = data.match(/^confirm:([0-9a-f-]{36})$/i))) {
    action = 'confirm'; args = {token:m[1]};
  }
} else if (/^\/(help|start)(?:@\w+)?$/i.test(text)) action = 'help';
else if (/^\/cancel$/i.test(text)) action = 'cancel';
else if (/^\/children$/i.test(text)) action = 'children';
else if ((m = text.match(/^\/feed\s+(.+?)\s+(\d{1,4})(?:\s+(\d{1,4}))?$/i))) {
  action = 'feed'; args = {name:m[1],amount:Number(m[2]),prepared:Number(m[3] || m[2])};
} else if ((m = text.match(/^(\d{1,4})(?:\s+(\d{1,4}))?$/))) {
  action = 'amount'; args = {amount:Number(m[1]),prepared:Number(m[2] || m[1])};
} else if ((m = text.match(/^\/(history|status|reset|childdelete)\s+(.+)$/i))) {
  action = m[1].toLowerCase(); args = {name:m[2].trim()};
} else if ((m = text.match(/^\/childadd\s+(.+?)\s+(\d{4}-\d{2}-\d{2})$/i))) {
  action = 'childadd'; args = {name:m[1],dob:m[2]};
} else if ((m = text.match(/^\/growth\s+(.+?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)$/i))) {
  action = 'growth'; args = {name:m[1],weight:Number(m[2]),height:Number(m[3])};
} else if ((m = text.match(/^\/delete\s+([0-9a-f-]{36})$/i))) {
  action = 'delete'; args = {feed_id:m[1]};
} else if ((m = text.match(/^\/edit\s+([0-9a-f-]{36})\s+(\d{1,4})\s+(\d{1,4})(?:\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})))?$/i))) {
  action = 'edit'; args = {feed_id:m[1],amount:Number(m[2]),prepared:Number(m[3]),...(m[4] ? {time:m[4]} : {})};
} else if ((m = text.match(/^\/stock\s+(\S+)\s+(\S+)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(\d+)\s+(\d+)$/i))) {
  action = 'stock'; args = {name:m[1],product:m[2],grams:Number(m[3]),scoop_g:Number(m[4]),scoop_ml:Number(m[5]),tins:Number(m[6]),lead:Number(m[7]),buffer:Number(m[8])};
}
// Telegram update_id provides transaction-level deduplication in the SQL RPC.
if (update.update_id == null) return [];
args.update_id = String(update.update_id);
return [{json:{chat_id:String(message.chat.id),action,args,callback_id:cb?.id || ''}}];
