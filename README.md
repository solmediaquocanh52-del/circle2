# CircleSwitcher v1.5.0 (iOS 15 - 16.3.1 Rootless)
- **Fix lỗi linker GitHub Actions (`___isOSVersionAtLeast`)**: Loại bỏ hoàn toàn `@available(iOS 15.0, *)`, dùng kiểm tra runtime `respondsToSelector:` chuẩn Objective-C và nâng `TARGET` lên `15.0` cho Rootless.
- **Bộ Asset đồ họa `@3x` (`layout/Library/Application Support/CircleSwitcher/`)**:
  - `glass_rim@3x.png`: Viền kính phản chiếu Liquid-Glass 3D bao quanh từng vòng tròn ứng dụng.
  - `orb_halo@3x.png`: Hào quang phát sáng mềm mại tự động đổi màu theo thông số Glow Hue.
  - `ambient_backdrop@3x.png`: Phông nền chiều sâu 3D khi mở trình đa nhiệm.
  - `prefs_banner@3x.png`: Banner nghệ thuật cho trang Cài đặt.
- **Smooth Motion Engine (Vật lý lò xo giảm chấn 120Hz)**:
  - Bộ giải lò xo `CSSpringStep` chia bước 2ms ổn định ở cả 60Hz và 120Hz ProMotion.
  - Nghiêng động theo lực vuốt (`Velocity-Coupled Tilt`) và cache `CGPath` giúp giảm tải GPU.
