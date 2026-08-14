# tools

本目录存放 WebP 支持所需的官方工具（Google libwebp 1.6.0，64 位 Windows）：

- `dwebp.exe`：把 WebP 解码成临时 PNG，供主脚本读取；
- `cwebp.exe`：把临时 PNG 编码成 WebP。

主脚本会依次在 `脚本目录\tools`、脚本目录中查找这两个文件，也会回退到系统的 PATH。

来源与许可：见仓库根目录的 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)（BSD 3-Clause）。
