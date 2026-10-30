# 第三方组件声明 / Third-Party Notices

本项目的**图形界面与 macOS 移植代码**为原创（MIT，见 `LICENSE`）。
解包引擎不是原创实现，而是直接使用并内嵌了下列开源项目，特此声明。

---

## 1. RePKG — PKG 解包 / TEX 转图引擎

- 项目：https://github.com/notscuffed/repkg
- 作者：notscuffed
- 许可证：**MIT**
- 用途：本项目通过子进程调用它完成 `scene.pkg` 解包与纹理转换；打包成 `.app` 时其编译产物被一并分发。
- 修改：为在 macOS 上构建运行，本项目对其做了 5 处改动（`net472 → net8.0`、移除未使用的 Windows 专属依赖、修复 `-c` 不复制预览图、`info` 路径显示、`project.json` 容错）。改动以补丁形式提供于 `tools/repkg-macos.patch`，未改变其原有算法。

```
MIT License

Copyright (c) 2019 notscuffed

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2. RePKG 内部依赖的库

这些库被编译进 RePKG 的产物，随引擎一起分发。完整许可证原文见上游仓库的
[THIRD-PARTY-NOTICES.txt](https://github.com/notscuffed/repkg/blob/master/THIRD-PARTY-NOTICES.txt)。

| 组件 | 作者 | 许可证 |
|---|---|---|
| CommandLineParser | Giacomo Stelluti Scala & Contributors | MIT |
| Newtonsoft.Json | James Newton-King | MIT |
| K4os.Compression.LZ4 | Milosz Krajewski | MIT |
| SixLabors.ImageSharp 2.1.9 | Six Labors | Apache-2.0 |
| DXT 解压代码（移植自 libsquish） | Xalcon @ mmowned.com-Forum | MIT |

Apache-2.0 全文见 https://www.apache.org/licenses/LICENSE-2.0 。
ImageSharp 的版权声明：`Copyright (c) Six Labors`。

## 3. 系统框架

界面使用 Apple 系统框架（SwiftUI / AppKit / ImageIO / CoreGraphics / Compression），
随 macOS 提供，不受本项目分发。

---

## 关于素材内容

本项目只处理用户本地已有的壁纸文件，不附带、不分发任何壁纸素材。
仓库内不含任何游戏或角色素材的图片、纹理或解包产物。
