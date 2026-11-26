# 일반 대화 추가 — 기존 V5 워크플로우 변경 사항만

SQL, 자격 증명, 모델, 스케줄은 변경하지 않습니다.

1. `Build Gemini request`, `Validate Gemini intent`, `Resolve short replies`의 Code 내용을 같은 이름의 `.js` 파일 내용 전체로 교체합니다. 파일은 `updates/conversation/`에 있습니다.
2. `Validate Gemini intent` 바로 뒤에 **IF** 노드를 추가합니다. 왼쪽 Expression `{{ $json.action }}`, String → is equal to, 오른쪽 Fixed `chat`.
3. **기존 Validate Gemini intent → Process command 직접 연결은 제거**합니다.
4. IF의 true는 기존 **Send reply**, false는 기존 **Process command**에 연결합니다. Process command → Format response → Send reply는 유지합니다.
5. Publish 후 `고맙다`에 일반 답장이 오는지 확인합니다. 실제 기록 입력은 확인 후 저장되는지 확인하세요. 기록 요청을 일반 대화로 대체하지 않습니다.

원하면 전체 생성물 `n8n/daddy-bob-jooseyo-v5-conversation.json`을 새 워크플로우로 가져올 수도 있습니다. 이 경우 기존 자격 증명을 다시 선택하고 이전 워크플로우는 중지해야 합니다.

일반 대화는 Google Gemini가 작성하고 DB RPC를 호출하지 않습니다. 기록/조회/수정/삭제/예약은 기존 검증 경로를 사용합니다. 감사 표현은 동의가 아니며, 공급자 오류나 기록 실패를 성공한 것처럼 답하지 않도록 합니다. 실제 모델 응답은 배포 후 확인이 필요합니다.
