# Приглашение на день рождения Александра — «Железный человек»

| Файл | Что это |
|---|---|
| `invitation-1-armor.png` | Вариант 1 «Броня»: красный металл, золото, дуговой реактор (2160×3240) |
| `invitation-1-armor.mp4` | Вариант 1, анимация 8 с (бесшовный повтор) для мессенджеров |
| `invitation-2-gala.png` | Вариант 2 «Праздник»: красно-золотые шары, медаль-реактор (2160×3240) |
| `invitation-2-gala.mp4` | Вариант 2, анимация 8 с |
| `source/` | HTML-исходники (статичные и анимированные), шрифты (OFL) и скрипты рендера |

Перерисовать PNG после правки HTML (из `source/`):

```sh
NODE_PATH=/opt/node22/lib/node_modules node render.js invitation-1-armor.html out.png --scale 2
NODE_PATH=/opt/node22/lib/node_modules node record.js invitation-1-armor-animated.html out.mp4 --seconds 8
```

`render.js` и `record.js` ищут Chromium и ffmpeg по путям из облачной среды, где делались файлы. В другом окружении эти пути в скриптах нужно поменять.
