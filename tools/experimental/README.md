# Puppet 静态预览实验

`puppet_preview_3539662091.py` 是针对 Workshop 3539662091 的独立可行性原型，尚未接入应用。它读取已解出的 MDLV0023 网格和 PNG 图集，绘制默认姿态；场景尺寸、位置和缩放固定取自该样本的 `scene.json`。它不支持其他壁纸的自动判定、动画、特效、时钟和粒子，也不保证图层和透明混合与 Mirage 完全一致。

运行需要 Python 3、Pillow 和 NumPy。先用项目的 repkg 完整解包此壁纸，再运行：

```sh
python3 tools/experimental/puppet_preview_3539662091.py <puppet.mdl路径> <图集PNG路径> <输出PNG路径>
```

实验时参考了 [pkg_parser 的 MDL 格式说明](https://github.com/wqlouis/pkg_parser/blob/crate/src/pkg_parser/README.md)；该项目使用 GPL 许可证，本实验未引入其代码或依赖。此逐三角形 CPU 原型运行较慢，不适合作为正式应用的渲染实现。
