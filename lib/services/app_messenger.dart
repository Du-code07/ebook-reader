import 'package:flutter/material.dart';

/// 앱 어느 화면에서든 아래 알림(SnackBar)을 띄우기 위한 열쇠 (MaterialApp에 연결)
final GlobalKey<ScaffoldMessengerState> appMessengerKey = GlobalKey<ScaffoldMessengerState>();
