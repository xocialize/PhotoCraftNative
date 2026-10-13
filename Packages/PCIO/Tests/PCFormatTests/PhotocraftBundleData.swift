// A `.pcraft` bundle as photocraft writes it, for `PhotocraftBundleTests`: the manifest exactly as
// serde_json's pretty printer writes photocraft's manifest model (field order, `null`s, `1.0`
// floats, internally tagged content), zstd frames shaped like ruzstd's (no content size, a window
// descriptor, an XXH64 checksum; made by libzstd 1.5.7 at levels -1…19), and object names computed
// with the reference BLAKE3 (the `blake3` crate, through blake3-wasm), not with this port.
// Test data for photocraft-format (crates/format), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

enum PhotocraftBundle {
    static let bgTileHash = "4c6df5c52ebc417b0a72c83f1514e8208f70c91e22dbdde02f1ac5637a766b27"
    static let paintTileHash = "933f9bb4bce10efa025c6e71d2e55d88ba87b2139e3b737512ddc7bd6d6a94e9"
    static let maskTileHash = "d57f284c58fbaf143c82daf9af8e25c890b604d9e87f1c867ae826975e7d0fe8"
    static let childTileHash = "c35d6e426123536068b4e421219c0bfbd78bd3a824a36914f9fa8be81eadc28a"

    /// Bundle path → base64 of the zstd frame.
    static let objects: [(String, String)] = [
        ("blobs/366cc690d570db7ab1640c1ae087d948e6f9a71a5b65fc8fb4cfec69a6f7dcae.zst", "KLUv/QQIVQgABBALKkloh6bF5AMiQWB/nr3c+xo5WHeWtdTzEjFQb46tzOsKKUhnhqXE4wIhQF9+nbzb+hk4V3aVtNPyETBPbo2sy+oJKEdmhaTD4gEgP159nLva+Rg3VnWUs9LxEC9ObYyryukIJ0ZlhKPC4QAfPl18m7rZ+Bc2VXSTstHwDy5NbIuqyegHJkVkg6LB4P8ePVx7mrnY9xY1VHOSsdDvDi1Ma4qpyOcGJURjgqHA3/4dPFt6mbjX9hU0U3KRsM/uDSxLaomox+YFJENigaC/3v0cO1p5mLfW9RQzUnGQr87tDCtKaYinxuUEI0JhgJ++3fwbOll4l7bV9BMyUXCPrs3sAQAAzQ78awryofI6"),
        ("blobs/4747de9f334d7b8554f3c39d2b2d51e6de5422967bb4fa9916ba9cc770cd1116.zst", "KLUv/QQAAQIAAyJBYH+evdz7GjlYd5a11PMSMVBvjq3M6wopSGeGpcTjAiFAX36dvNv6GThXdpW00/IRME9ujazL6gkoR2aFpAhMKU8="),
        ("blobs/4fc2f836ae3812027dbda6578aa829058feb13b26b88ae89d70753317a7363d8.zst", "KLUv/QQAAQIADy5NbIuqyegHJkVkg6LB4P8ePVx7mrnY9xY1VHOSsdDvDi1Ma4qpyOcGJURjgqHA3/4dPFt6mbjX9hU0U3KRsJ92UAY="),
        ("blobs/9187ec18da9ec252b5f8617a7ee720b84244305ad266cd43faad33eebb5294f2.zst", "KLUv/QQAIQAABSRDYiJx6KU="),
        ("blobs/dc63bb0ae789f39960508269dd75e126dd1227cfe76606600cb7bb06db394c35.zst", "KLUv/QQAVQgABBABID9efZy72vkYN1Z1lLPS8RAvTm2Mq8rpCCdGZYSjwuEAHz5dfJu62fgXNlV0k7LR8A8uTWyLqsnoByZFZIOiweD/Hj1ce5q52PcWNVRzkrHQ7w4tTGuKqcjnBiVEY4KhwN/+HTxbepm41/YVNFNykbDP7g0sS2qJqMfmBSRDYoGgv979HDtaeZi31vUUM1JxkK/O7QwrSmmIp8blBCNCYYCfvt38GzpZeJe21fQTMlFwj67N7AsqSWiHpsXkAyJBYH+evdz7GjlYd5a11PMSMVBvjq3M6wopSGeGpcTjAiFAX36dvNv6GThXdpW00/IRME9ujazL6gkoR2aFpMPiAQAA8QFqTQEUqxp9"),
        ("blobs/eed501a1a2cf39c218f3346df6d591f6b236540ecfebf3de15f5775585c312b9.zst", "KLUv/QQAoQAAEC9ObYyryukIJ0ZlhKPC4QAfPl0Brwij"),
        ("tiles/4c6df5c52ebc417b0a72c83f1514e8208f70c91e22dbdde02f1ac5637a766b27.zst", "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"),
        ("tiles/933f9bb4bce10efa025c6e71d2e55d88ba87b2139e3b737512ddc7bd6d6a94e9.zst", "KLUv/QRAHAUANhAjIoDbZuDedn63m3++s5/f7Lef7e1nt+9t53e7+ec7+/lEjBQYABkAGQA1HMMtnMIlHMIdnMEVHMENnMAFHMB9rhXrOI7bOI3LOIy7OIurOIqbOImLOIh7OIcD13Ist3Iql3Iod3ImV3IkN3IiF3Ig93EeA63neG7ndC7ncO7mbK7maG7mZC7mYO7lXAIEAH0/2KF/P0DWgQB+oJp7AB1gAQMAEAAslzQM"),
        ("tiles/c35d6e426123536068b4e421219c0bfbd78bd3a824a36914f9fa8be81eadc28a.zst", "KLUv/QRIzCoAxCgAAAAAAAD//wEBAgIDAwQEBQUGBgcHCAgJCQoKCwsMDA0NDg4PDxAQERESEhMTFBQVFRYWFxcYGBkZGhobGxwcHR0eHh8fICAhISIiIyMkJCUlJiYnJygoKSkqKisrLCwtLS4uLy8wMDExMjIzMzQ0NTU2Njc3ODg5OTo6Ozs8PD09Pj4/P0BAQUFCQkNDRERFRUZGR0dISElJSkpLS0xMTU1OTk9PUFBRUVJSU1NUVFVVVlZXV1hYWVlaWltbXFxdXV5eX19gYGFhYmJjY2RkZWVmZmdnaGhpaWpqa2tsbG1tbm5vb3BwcXFycnNzdHR1dXZ2d3d4eHl5enp7e3x8fX1+fn9/gICBgYKCg4OEhIWFhoaHh4iIiYmKiouLjIyNjY6Oj4+QkJGRkpKTk5SUlZWWlpeXmJiZmZqam5ucnJ2dnp6fn6CgoaGioqOjpKSlpaamp6eoqKmpqqqrq6ysra2urq+vsLCxsbKys7O0tLW1tra3t7i4ubm6uru7vLy9vb6+v7/AwMHBwsLDw8TExcXGxsfHyMjJycrKy8vMzM3Nzs7Pz9DQ0dHS0tPT1NTV1dbW19fY2NnZ2trb29zc3d3e3t/f4ODh4eLi4+Pk5OXl5ubn5+jo6enq6uvr7Ozt7e7u7+/w8PHx8vLz8/T09fX29vf3+Pj5+fr6+/v8/P39/v7//wAAAAABAQICAwMEBAUFBgYHBwgICQkKCgsLDAwNDQ4ODw8QEBEREhITExQUFRUWFhcXGBgZGRoaGxscHB0dHh4fHyAgISEiIiMjJCQlJSYmJycoKCkpKiorKywsLS0uLi8vMDAxMTIyMzM0NDU1NjY3Nzg4OTk6Ojs7PDw9PT4+Pz8/P////r6opD84SfOv6AEUAP7hBhbFBY1waFkCTJRcgVBR8oVoaEiLBKloKBAkw7IAqCi5AsKi5AtR0ZAWCZTRUCBQhmUBYFFyBYRFyReiwiEtEiijoYCgDMsCwCLlCgiLlC9EhkNaRFBGQwFBGZYFgEnKFRAmKV+QDIe0iKCMhgKCMiwLAJOUKyBMUr4gGQ5pEUEaDQUEaVgWACYpV0CYpHxBMizSIoI0GgoI0rAsAExSroAwUfmCZGikRQSpNBQQpGJZAJioXAFhouQL0dCQFglS0VAgSIZlAVBRcgVCRckXoqEhLRIko6FAoAzLAsCi5AoIi5IvREVDWiRQRkOBQBmWBYBFyRUQFilfiAqHtIigjIYCgjIsCwCLRJcrMAC9/03X3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/d3T3z393dPfPf3d0989/bunv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+runv3v6u6e/e/q7p797+rvHr7+xXv/+A2wFAIQEAAAAAEBAQUFCQkNDRERFRUZGR0dISElJSkpLS0xMTU1OTk9PUFBRUVJSU1NUVFVVVlZXV1hYWVlaWltbXFxdXV5eX19fX///v96Y9F+QAAAUAP9jdMJ//vzPn//58z9//ufP//z5nz//8+d//vzPn//58z9//ufP//z5nz//8+d//vzPn//58z9//ufP//z5nz//8+d//vzPn//58z9//ufP//z5nz//Xv4DbAUAhAQAAAAAYGBhYWJiY2NkZGVlZmZnZ2hoaWlqamtrbGxtbW5ub29wcHFxcnJzc3R0dXV2dnd3eHh5eXp6e3t8fH19fn5/f39///+/3pj0X5AAABQA/2N0wn/+/M+f//nzP3/+58///PmfP//z53/+/M+f//nzP3/+58///PmfP//z53/+/M+f//nzP3/+58///PmfP//z53/+/M+f//nzP3/+58///PmfP/9e/gNsBQCEBAAAAACAgIGBgoKDg4SEhYWGhoeHiIiJiYqKi4uMjI2Njo6Pj5CQkZGSkpOTlJSVlZaWl5eYmJmZmpqbm5ycnZ2enp+fn5///7/emPRfkAAAFAD/Y3TCf/78z5//+fM/f/7nz//8+Z8///Pnf/78z5//+fM/f/7nz//8+Z8///Pnf/78z5//+fM/f/7nz//8+Z8///Pnf/78z5//+fM/f/7nz//8+Z8//17+A2wFAIQEAAAAAKCgoaGioqOjpKSlpaamp6eoqKmpqqqrq6ysra2urq+vsLCxsbKys7O0tLW1tra3t7i4ubm6uru7vLy9vb6+v7+/v///v96Y9F+QAAAUAP9jdMJ//vzPn//58z9//ufP//z5nz//8+d//vzPn//58z9//ufP//z5nz//8+d//vzPn//58z9//ufP//z5nz//8+d//vzPn//58z9//ufP//z5nz//Xv4DbAUAhAQAAAAAwMDBwcLCw8PExMXFxsbHx8jIycnKysvLzMzNzc7Oz8/Q0NHR0tLT09TU1dXW1tfX2NjZ2dra29vc3N3d3t7f39/f//+/3pj0X5AAABQA/2N0wn/+/M+f//nzP3/+58///PmfP//z53/+/M+f//nzP3/+58///PmfP//z53/+/M+f//nzP3/+58///PmfP//z53/+/M+f//nzP3/+58///PmfP/9e/gNtBQCEBAAAAADg4OHh4uLj4+Tk5eXm5ufn6Ojp6erq6+vs7O3t7u7v7/Dw8fHy8vPz9PT19fb29/f4+Pn5+vr7+/z8/f3+/v///////7/emPRfkAAAFAD/Y3TCf/78z5//+fM/f/7nz//8+Z8///Pnf/78z5//+fM/f/7nz//8+Z8///Pnf/78z5//+fM/f/7nz//8+Z8///Pnf/78z5//+fM/f/7nz//8+Z8//17+A4wjDBs="),
        ("tiles/d57f284c58fbaf143c82daf9af8e25c890b604d9e87f1c867ae826975e7d0fe8.zst", "KLUv/QQw1QoAoscFBuAPAGBMCqoC8P//////+/9/VVVVVQWAhaiQsmsgR3KSJNkBEvh/B4F3EDgIGIShMIzw1C0Ge6+3Cy+xqjYXTiq/wWVn7v4BiuAfkKR/ALL9A47oH2As/AOK/D+AWPoHDPE/QNj5BwSZfwCw+Af8xj/Aw39AP/wDeOEfsIF/gD78A3LjH4DBP+Be+A+shX8ABf4B8/APkMU/IAL8B77DP8B1+A9kxD9gffgPTB3/gQfjP7D8+A8cPf4DAxH+Az8m/gZ0ZPwN0Mj4G3CR8T9wIkc/A65pvDbgMZsEWF2jBuALYciwrOhjQNHKQLI9w4dOwyHWwJBtTtC3IEQcDJBzbr4KRLhzy/d1qXs2n/LD53x8ms9jAOYAvvEVX/kcnyMES4pv+cB3BwhAMbHpOBKQPY+EIxMSSwlaLZDG/IUaJZQLKnrOKHQ6IBmSE+uqGHqn+CbOB1sUBdG94Ao="),
    ]

    static let manifest = #"""
{
  "format_version": 1,
  "generator": "photocraft-format 0.1.0",
  "document": {
    "id": 1,
    "name": "From photocraft",
    "size": {
      "width": 300,
      "height": 200
    },
    "resolution_dpi": 300.0,
    "mode": "Rgb",
    "depth": "U8",
    "icc_profile": "dc63bb0ae789f39960508269dd75e126dd1227cfe76606600cb7bb06db394c35",
    "layers": [
      {
        "id": 2,
        "name": "Background",
        "visible": true,
        "locks": {
          "transparency": true,
          "pixels": false,
          "position": true,
          "artboard": false,
          "all": false
        },
        "blend": "Normal",
        "opacity": 1.0,
        "fill_opacity": 1.0,
        "clipped": false,
        "mask": null,
        "vector_mask": null,
        "effects": {
          "enabled": true,
          "items": [],
          "psd_raw": null,
          "reference": null
        },
        "label": "None",
        "content": {
          "kind": "raster",
          "surface": {
            "format": {
              "mode": "Rgb",
              "sample": "U8",
              "alpha": true
            },
            "default": "00000000",
            "tiles": [
              {
                "tx": 0,
                "ty": 0,
                "hash": "4c6df5c52ebc417b0a72c83f1514e8208f70c91e22dbdde02f1ac5637a766b27"
              },
              {
                "tx": 1,
                "ty": 0,
                "hash": "4c6df5c52ebc417b0a72c83f1514e8208f70c91e22dbdde02f1ac5637a766b27"
              }
            ]
          }
        },
        "psd_blocks": [],
        "psd_id": null,
        "fill_cache": null,
        "link_group": null,
        "video": null
      },
      {
        "id": 3,
        "name": "Paint",
        "visible": true,
        "locks": {
          "transparency": false,
          "pixels": false,
          "position": false,
          "artboard": false,
          "all": false
        },
        "blend": "Multiply",
        "opacity": 0.75,
        "fill_opacity": 1.0,
        "clipped": false,
        "mask": {
          "surface": {
            "format": {
              "mode": "Grayscale",
              "sample": "U8",
              "alpha": false
            },
            "default": "00",
            "tiles": [
              {
                "tx": 0,
                "ty": 0,
                "hash": "d57f284c58fbaf143c82daf9af8e25c890b604d9e87f1c867ae826975e7d0fe8"
              }
            ]
          },
          "enabled": true,
          "linked": true,
          "density": 1.0,
          "feather": 0.0
        },
        "vector_mask": null,
        "effects": {
          "enabled": true,
          "items": [
            {
              "ColorOverlay": {
                "common": {
                  "enabled": true,
                  "blend": "Normal",
                  "opacity": 0.5
                },
                "color": {
                  "mode": "Rgb",
                  "c": [
                    1.0,
                    0.0,
                    0.0,
                    0.0
                  ],
                  "alpha": 1.0
                }
              }
            }
          ],
          "psd_raw": "4747de9f334d7b8554f3c39d2b2d51e6de5422967bb4fa9916ba9cc770cd1116",
          "reference": null
        },
        "label": "Red",
        "content": {
          "kind": "raster",
          "surface": {
            "format": {
              "mode": "Rgb",
              "sample": "U8",
              "alpha": true
            },
            "default": "00000000",
            "tiles": [
              {
                "tx": 0,
                "ty": 0,
                "hash": "933f9bb4bce10efa025c6e71d2e55d88ba87b2139e3b737512ddc7bd6d6a94e9"
              }
            ]
          }
        },
        "psd_blocks": [
          [
            "6c6e7372",
            "9187ec18da9ec252b5f8617a7ee720b84244305ad266cd43faad33eebb5294f2"
          ]
        ],
        "psd_id": 42,
        "fill_cache": null,
        "link_group": null,
        "excluded_channels": 2,
        "video": null
      },
      {
        "id": 4,
        "name": "Group",
        "visible": true,
        "locks": {
          "transparency": false,
          "pixels": false,
          "position": false,
          "artboard": false,
          "all": false
        },
        "blend": "PassThrough",
        "opacity": 1.0,
        "fill_opacity": 1.0,
        "clipped": false,
        "mask": null,
        "vector_mask": null,
        "effects": {
          "enabled": true,
          "items": [],
          "psd_raw": null,
          "reference": null
        },
        "label": "None",
        "content": {
          "kind": "group",
          "children": [
            {
              "id": 5,
              "name": "Deep",
              "visible": true,
              "locks": {
                "transparency": false,
                "pixels": false,
                "position": false,
                "artboard": false,
                "all": false
              },
              "blend": "Normal",
              "opacity": 1.0,
              "fill_opacity": 1.0,
              "clipped": false,
              "mask": null,
              "vector_mask": null,
              "effects": {
                "enabled": true,
                "items": [],
                "psd_raw": null,
                "reference": null
              },
              "label": "None",
              "content": {
                "kind": "raster",
                "surface": {
                  "format": {
                    "mode": "Rgb",
                    "sample": "U16",
                    "alpha": true
                  },
                  "default": "0000000000000000",
                  "tiles": [
                    {
                      "tx": -1,
                      "ty": 2,
                      "hash": "c35d6e426123536068b4e421219c0bfbd78bd3a824a36914f9fa8be81eadc28a"
                    }
                  ]
                }
              },
              "psd_blocks": [],
              "psd_id": null,
              "fill_cache": null,
              "link_group": null,
              "video": null
            }
          ],
          "expanded": false,
          "artboard": null
        },
        "psd_blocks": [],
        "psd_id": null,
        "fill_cache": null,
        "link_group": null,
        "video": null
      },
      {
        "id": 6,
        "name": "Invert",
        "visible": false,
        "locks": {
          "transparency": false,
          "pixels": false,
          "position": false,
          "artboard": false,
          "all": false
        },
        "blend": "Normal",
        "opacity": 1.0,
        "fill_opacity": 1.0,
        "clipped": false,
        "mask": null,
        "vector_mask": null,
        "effects": {
          "enabled": true,
          "items": [],
          "psd_raw": null,
          "reference": null
        },
        "label": "None",
        "content": {
          "kind": "adjustment",
          "adjustment": "Invert"
        },
        "psd_blocks": [],
        "psd_id": null,
        "fill_cache": null,
        "link_group": null,
        "video": null
      },
      {
        "id": 7,
        "name": "Exposure",
        "visible": true,
        "locks": {
          "transparency": false,
          "pixels": false,
          "position": false,
          "artboard": false,
          "all": false
        },
        "blend": "Normal",
        "opacity": 1.0,
        "fill_opacity": 1.0,
        "clipped": false,
        "mask": null,
        "vector_mask": null,
        "effects": {
          "enabled": true,
          "items": [],
          "psd_raw": null,
          "reference": null
        },
        "label": "None",
        "content": {
          "kind": "adjustment",
          "adjustment": {
            "Exposure": {
              "exposure": 0.5,
              "offset": 0.0,
              "gamma": 1.0
            }
          }
        },
        "psd_blocks": [],
        "psd_id": null,
        "fill_cache": null,
        "link_group": null,
        "video": null
      },
      {
        "id": 8,
        "name": "Fill",
        "visible": true,
        "locks": {
          "transparency": false,
          "pixels": false,
          "position": false,
          "artboard": false,
          "all": false
        },
        "blend": "Screen",
        "opacity": 1.0,
        "fill_opacity": 1.0,
        "clipped": false,
        "mask": null,
        "vector_mask": null,
        "effects": {
          "enabled": true,
          "items": [],
          "psd_raw": null,
          "reference": null
        },
        "label": "None",
        "content": {
          "kind": "fill",
          "fill": {
            "Solid": {
              "mode": "Rgb",
              "c": [
                0.25,
                0.5,
                0.75,
                0.0
              ],
              "alpha": 1.0
            }
          }
        },
        "psd_blocks": [],
        "psd_id": null,
        "fill_cache": null,
        "link_group": null,
        "video": null
      },
      {
        "id": 9,
        "name": "Hi",
        "visible": true,
        "locks": {
          "transparency": false,
          "pixels": false,
          "position": false,
          "artboard": false,
          "all": false
        },
        "blend": "Normal",
        "opacity": 1.0,
        "fill_opacity": 1.0,
        "clipped": false,
        "mask": null,
        "vector_mask": null,
        "effects": {
          "enabled": true,
          "items": [],
          "psd_raw": null,
          "reference": null
        },
        "label": "None",
        "content": {
          "kind": "text",
          "text": "Hi ✓",
          "font_family": "Inter",
          "size_pt": 24.0,
          "color": {
            "mode": "Rgb",
            "c": [
              0.0,
              0.0,
              1.0,
              0.0
            ],
            "alpha": 1.0
          },
          "transform": {
            "m": [
              1.0,
              0.0,
              0.0,
              1.0,
              10.0,
              20.0
            ]
          },
          "cache": null,
          "psd_raw": null,
          "runs": [],
          "paragraphs": [],
          "shape": "Point",
          "orientation": "Horizontal",
          "antialias": "Smooth",
          "warp": null
        },
        "psd_blocks": [],
        "psd_id": null,
        "fill_cache": null,
        "link_group": null,
        "video": null
      },
      {
        "id": 10,
        "name": "Smart",
        "visible": true,
        "locks": {
          "transparency": false,
          "pixels": false,
          "position": false,
          "artboard": false,
          "all": false
        },
        "blend": "Normal",
        "opacity": 1.0,
        "fill_opacity": 1.0,
        "clipped": false,
        "mask": null,
        "vector_mask": null,
        "effects": {
          "enabled": true,
          "items": [],
          "psd_raw": null,
          "reference": null
        },
        "label": "None",
        "content": {
          "kind": "smart",
          "contents_id": 77,
          "source": {
            "kind": "embedded",
            "file_name": "inner.png",
            "blob": "366cc690d570db7ab1640c1ae087d948e6f9a71a5b65fc8fb4cfec69a6f7dcae"
          },
          "transform": {
            "m": [
              0.5,
              0.0,
              0.0,
              0.5,
              0.0,
              0.0
            ]
          },
          "smart_filters": [
            {
              "command": "filter.blur.gaussian",
              "params": {
                "radius": 2.5
              },
              "blend": "Normal",
              "opacity": 1.0,
              "visible": true
            }
          ],
          "cache": null,
          "psd_raw": null,
          "filters_enabled": true,
          "filter_mask": null,
          "warp": null,
          "stack_mode": null
        },
        "psd_blocks": [],
        "psd_id": null,
        "fill_cache": null,
        "link_group": null,
        "video": null
      }
    ],
    "channels": [
      {
        "name": "Alpha 1",
        "surface": {
          "format": {
            "mode": "Grayscale",
            "sample": "U8",
            "alpha": false
          },
          "default": "00",
          "tiles": [
            {
              "tx": 0,
              "ty": 0,
              "hash": "d57f284c58fbaf143c82daf9af8e25c890b604d9e87f1c867ae826975e7d0fe8"
            }
          ]
        },
        "spot": null,
        "color": {
          "mode": "Rgb",
          "c": [
            1.0,
            0.0,
            0.0,
            0.0
          ],
          "alpha": 1.0
        },
        "opacity": 0.5,
        "indicates": "maskedAreas"
      }
    ],
    "guides": {
      "horizontal": [
        10.0
      ],
      "vertical": []
    },
    "selection": null,
    "metadata": {
      "xmp": "<x:xmpmeta/>",
      "exif": "4fc2f836ae3812027dbda6578aa829058feb13b26b88ae89d70753317a7363d8",
      "psd_resources": [
        [
          1036,
          "thumb",
          "eed501a1a2cf39c218f3346df6d591f6b236540ecfebf3de15f5775585c312b9"
        ]
      ],
      "psd_global_blocks": []
    },
    "global_light": {
      "angle": 120.0,
      "altitude": 30.0
    },
    "paths": [],
    "work_path": null,
    "clipping_path": null,
    "quick_mask": null,
    "patterns": [],
    "color_table": null,
    "duotone": null,
    "layer_comps": [],
    "last_applied_comp": null,
    "last_document_state": null,
    "variables": {
      "defs": [],
      "data_sets": [],
      "active": null
    },
    "timeline": null,
    "measurement": {
      "scale": {
        "pixel_length": 1.0,
        "logical_length": 1.0,
        "units": "pixels"
      },
      "count_groups": [],
      "active_count_group": 0,
      "ruler": null
    },
    "notes": [],
    "text_styles": {
      "character": [],
      "paragraph": [],
      "basic": {
        "id": 0,
        "name": "",
        "para_attrs": {},
        "char_attrs": {}
      },
      "psd_raw": null
    }
  },
  "thumbnail": null,
  "composite": null
}
"""#
}
