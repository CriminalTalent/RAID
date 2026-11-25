# RAID 통합본

전투봇(TH3V151T0R5_B)과 조사봇(TH3V151T0R5_F)을 한 저장소에 모은 통합본입니다.
원본 두 저장소는 그대로 유지되며, 이 저장소는 레이드 웹 페이지(관리자/참여자/관전자) 작업을 이어가는 곳입니다.

| 폴더 | 내용 | 원본 |
|---|---|---|
| `battle/` | 전투봇 + 레이드 웹 페이지 | TH3V151T0R5_B `1251a4b` + 관전자 페이지 |
| `scout/` | 조사봇 | TH3V151T0R5_F `255c1ae` |

각 폴더는 독립적으로 실행됩니다. `.env`와 `credentials.json`은 저장소에 없으므로 기존 서버 폴더에서 복사해야 합니다.

## 서버 설치
```
cd ~
git clone https://github.com/CriminalTalent/RAID.git
cp ~/TH3V151T0R5_B/.env ~/TH3V151T0R5_B/credentials.json ~/RAID/battle/
cp ~/TH3V151T0R5_F/.env ~/TH3V151T0R5_F/credentials.json ~/RAID/scout/
cd ~/RAID/battle && bundle install
cd ~/RAID/scout && bundle install
```

## 실행 (기존 봇과 동시에 켜지 말 것 — 같은 계정으로 이중 응답함)
```
pm2 stop battle_bot scout_bot
pm2 start ~/RAID/battle/main.rb --name raid_battle --interpreter ruby --cwd ~/RAID/battle
pm2 start ~/RAID/scout/main.rb  --name raid_scout  --interpreter ruby --cwd ~/RAID/scout
pm2 save
```
원래대로 돌아가기: `pm2 delete raid_battle raid_scout && pm2 start battle_bot scout_bot`

## 레이드 웹 페이지
`battle/WEB.md` 참고.
