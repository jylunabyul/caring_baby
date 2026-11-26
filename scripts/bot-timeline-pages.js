// Preserve every timeline line. Telegram has a 4096-character limit; leave room for headings/entities.
if(Array.isArray($json.timeline_lines)){
 const header=typeof $json.reply==='string'?$json.reply:'아버님, 하루 기록입니다. (한국 시간)';
 if(!$json.timeline_lines.length)return [{json:{...$json,reply:header,buttons:[]}}];
 const limit=2400,blocks=[];let block='';
 for(const line of $json.timeline_lines){
  const parts=[];let chunk='';
  for(const char of String(line)){if(chunk.length+char.length>limit){parts.push(chunk);chunk='';}chunk+=char;}
  if(chunk)parts.push(chunk);
  for(const part of parts){
   if(block && (block+'\n'+part).length>limit){blocks.push(block);block='';}
   block+=(block?'\n':'')+part;
  }
 }
 if(block)blocks.push(block);
 return blocks.map((text,i)=>({json:{chat_id:$json.chat_id,reply:header+(blocks.length>1?`\n[${i+1}/${blocks.length}]`:'')+'\n\n'+text,buttons:[]},pairedItem:{item:0}}));
}
if($json.reply && typeof $json.reply==='string')return [{json:{...$json,silent:false}}];
return [{json:{chat_id:'9114513581',reply:'아버님, 서버 응답을 확인하지 못했습니다. 저장 여부를 조회한 뒤 다시 말씀해 주세요.',buttons:[]}}];
