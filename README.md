# CircleSwitcher v1.2.0 (iOS 14 - 16.3.1 Rootless)
Thay đổi App Switcher thành vòng tròn 3D cuộn vô tận cả hai chiều trái và phải.

## Build tự động trên GitHub Actions
1. Kéo thả toàn bộ các file và thư mục (bao gồm cả thư mục ẩn `.github`) lên repo GitHub của bạn.
2. Vào tab **Actions** trên GitHub -> chọn **Build CircleSwitcher (.deb)** -> tải file `.deb` trong mục **Artifacts**.
3. Cài bằng **Sileo** và **Respring**.

## Build trực tiếp bằng Theos trên iPhone
```bash
make clean && make package
```
