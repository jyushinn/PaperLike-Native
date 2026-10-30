# 图标资源

`Paperlike-Native.icon/`是应用图标的正式Icon Composer源文件，包含暖金渐变和玻璃效果。Composer使用闭合轮廓素材，避免开放描边在玻璃渲染中出现多余边缘。

`Paperlike-Native-rendered.png`和`Paperlike-Native.icns`是兼容资源。构建时有完整Xcode则编译当前Composer文档，并为“关于”页导出高清PNG；工具不可用时使用仓库中的兼容资源。

`paperlike-native-mark.svg`保留可编辑的单色描边版本。

## 连接状态

菜单栏和控制浮层通过`ConnectionStatusIcon`共用以下单色模板图标，由系统适配深浅外观：

| 状态 | 图形 |
| --- | --- |
| 已连接 | 旋钮与三颗墨点 |
| 连接中 | 保留指针，整圈墨点顺时针递减 |
| 未连接 | 旋钮加斜线 |
| 连接异常 | 旋钮内使用感叹号 |

源文件位于`../MenuBarIcons/`。菜单栏图标16pt，浮层图标20pt；连接中图形为静态图标。
