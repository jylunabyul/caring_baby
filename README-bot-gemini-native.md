# n8n 기본 Google Gemini 노드 버전

파일: `n8n/daddy-bob-jooseyo-gemini-native.json`

기존 Gemini HTTP Request를 n8n 기본 **Google Gemini → Text → Message a Model** 노드로 교체했습니다. n8n langchain 노드 패키지 2.43.6의 노드 정의·필드·raw 출력 형식을 확인했습니다. 실제 API 연결 테스트는 포함하지 않습니다.

1. 새 워크플로우에서 JSON을 Import from File로 가져옵니다.
2. `Google Gemini - Message a model`을 열어 **Google Gemini(PaLM) API** 자격 증명을 생성하고 본인의 Gemini API 키를 입력합니다. 자격 증명 목록에 표시되는 이름은 n8n 버전에 따라 다를 수 있습니다. Header Auth는 필요하지 않습니다.
3. 모델은 `models/gemini-2.5-flash`입니다. 계정에서 사용 가능한 모델을 선택하세요. `Output Content as JSON=true`, `Simplify Output=false`를 유지합니다. 후속 Decode 노드는 raw candidates 응답을 기대합니다.
4. Supabase·Telegram 노드에 기존 자격 증명을 선택합니다. DB는 V3를 그대로 사용하므로 SQL 변경은 없습니다.
5. 기존 봇 워크플로우를 Unpublish한 다음 새 워크플로우만 Publish합니다. `/help`와 자연어 입력을 확인하고, 실제 기록을 저장할 때만 확인 버튼 또는 동의 답변을 사용하세요.

사용자 입력·제한된 기록 컨텍스트가 Google에 전달됩니다. API 키나 확인 토큰은 프롬프트에 넣지 않습니다. native 노드는 JSON 모드와 프롬프트의 필드 정의를 사용하며, HTTP 버전의 강제 responseSchema와 다릅니다. 필드·허용 명령·아이·기록 ID·확인 토큰의 별도 검증은 유지합니다. Gemini 사용량·권한 오류도 별도 안내합니다. 기본 야간 알림 휴식은 한국 시간 22:00~08:00이며 수유 필요 여부에 관한 판단은 아닙니다.
