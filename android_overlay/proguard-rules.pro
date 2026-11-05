# AdMob이 쓰는 WorkManager의 Room 구현체가 릴리스 축소 과정에서 망가져 시작 시 충돌했다.
-keep class androidx.work.** { *; }
-keep class androidx.room.** { *; }
-keep class * extends androidx.room.RoomDatabase { *; }
# 프로토타입에서는 오류 위치를 읽을 수 있도록 난독화와 최적화를 끈다.
-dontobfuscate
-dontoptimize
