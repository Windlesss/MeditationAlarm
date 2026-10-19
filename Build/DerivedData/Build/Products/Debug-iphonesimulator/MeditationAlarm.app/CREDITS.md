# 音频素材署名

所有素材来自 Wikimedia Commons，均为 CC0 / 公有领域 / CC BY / CC BY-SA 授权。
**App 上架前必须在「设置 - 关于」页展示本文件内容**（CC BY 与 CC BY-SA 的署名要求）。

## 提示音（chimes）

| 文件 | 音色 | 时长 | 授权 | 作者 |
|---|---|---|---|---|
| `chimes/bowl-deep-01.m4a` | 咚 · 颂钵 1 | 3.0s | Public domain | BambooBeast |
| `chimes/bowl-deep-02.m4a` | 咚 · 颂钵 2 | 2.8s | Public domain | BambooBeast |
| `chimes/bowl-large-hit.m4a` | 咚 · 大颂钵敲击 | 3.0s | CC BY-SA 4.0 | דג בלי מלח |
| `chimes/bowl-small-hit.m4a` | 咚 · 小颂钵敲击 | 3.0s | CC BY-SA 4.0 | דג בלי מלח |
| `chimes/bowl-small.m4a` | 咚 · 小藏钵 | 2.8s | CC BY-SA 4.0 | Cassa342 |
| `chimes/chime-tubebell.m4a` | 叮 · 管钟 | 2.4s | CC0 | gsb1039 |
| `chimes/rin-friction.m4a` | 叮 · 引磬摩擦 | 2.8s | CC BY-SA 4.0 | MichaelMaggs |
| `chimes/rin-strike.m4a` | 叮 · 引磬敲击 | 2.4s | CC BY-SA 4.0 | MichaelMaggs |

## 背景音（ambient）

| 文件 | 音色 | 时长 | 授权 | 作者 |
|---|---|---|---|---|
| `ambient/rain.m4a` | 雨声 | 41.0s | Public domain | ezwa |
| `ambient/rain-window.m4a` | 雨打窗 | 77.7s | Public domain | cori |
| `ambient/ocean.m4a` | 海浪 | 116.0s | CC BY 3.0 | Luftrum |
| `ambient/sea.m4a` | 海潮 | 16.9s | CC BY-SA 4.0 | Ganesh Mohan T |
| `ambient/water-flow.m4a` | 流水 | 92.3s | Public domain | stephan |
| `ambient/stream.m4a` | 溪流 | 27.0s | CC0 | Ksd5 |
| `ambient/forest-birds.m4a` | 林间鸟鸣 | 428.6s | CC BY-SA 4.0 | Matutinho |

## 加工说明

- 原始格式 Ogg Vorbis / FLAC / WAV 已统一转码为 **AAC 44.1kHz 立体声 .m4a**（iOS 原生解码，Ogg 与 FLAC 在 iOS 上支持不佳）
- 提示音：定位能量峰值点后截取 **2.4–3.0 秒**（清脆"叮" 2.4s / 钵音"咚" 3.0s），施加指数衰减包络（起音 0.1s 后开始），尾部自然归零不爆音
- 提示音经 `afftdn` 轻度降噪（nf=-30, nr=8）后峰值归一至 -1 dBFS，各条响度一致
- 背景音：末尾 4 秒与开头做等长交叠混音（`amix`），循环点无明显接缝
- **注意**：部分 Commons 录音是「摩擦演奏」而非单次敲击，能量最响处并不在起始位置（如 rin-strike 峰值在 3.4s、rin-friction 在 12.6s），因此按能量峰值定位裁剪，而非按静音起点

## 替换/补充

若后续换成自制或商业素材，只需替换同名文件并更新本表即可，代码无需改动（走 `SoundSource` 抽象）。
