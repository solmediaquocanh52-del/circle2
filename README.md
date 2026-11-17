# CircleSwitcher v2.0.0 — Liquid Glass Edition (iOS 14 → iOS 18+)
Hỗ trợ đầy đủ **tất cả các dòng iPhone & iPad (`arm64` / `arm64e`) từ iOS 14 đến iOS 18+** (cả **Rootful** và **Rootless**).

### Các sửa lỗi & nâng cấp chính trong v2.0.0
1. **Sửa triệt để lỗi thẻ bị bóp thành sọc dọc mỏng & vẫn là hình chữ nhật**: Ép khung nội dung `SBAppSwitcherPageView` / `_UIPortalView` về tỷ lệ vuông `1:1` và khóa `cornerRadius = đường_kính / 2` ngay trên lớp phần cứng của CoreAnimation.
2. **Sửa lỗi icon gốc tách rời bay lơ lửng**: Ẩn hoàn toàn header/icon container gốc của iOS khi vòng tròn kích hoạt.
3. **Sửa lỗi chạm nhầm mở thanh Shelf (`+`)**: Khóa quyền nhận chạm trên toàn bộ vòng tròn (chạm vòng tròn giữa để mở app, chạm hai bên để xoay mượt).
4. **Sửa lỗi mờ nội dung bên trong thẻ**: Tắt mặc định Motion Blur trên mặt thẻ, khóa `contentsScale = @3x` và `shouldRasterize = NO`.
5. **GPU Metal Liquid Glass Shader + 4 Preset 1 chạm**: Tùy chỉnh độ cong khúc xạ mép kính, độ bóng viền, tán sắc và ánh màu kính ngay trong Cài đặt.
