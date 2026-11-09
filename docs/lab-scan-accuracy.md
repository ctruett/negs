# Lab scan accuracy

Written by `scripts/lab_scan/report.py` against Color Precision's studio scans of the
ColorChecker Digital SG (140 patches). Hue error in degrees (lower is better), after
per-channel normalisation on the neutrals; ΔE is OKLab ×100 after one luminance scale.
The old direct scan shows a negative uninverted, so it is scored on slides only.
B&W is scored on ΔE alone (it has no hue). Renders are sRGB, as the lab's files are.
Training: 0 and +1 EV. Held out: −1 and +2 EV, and all of Portra 800 and UltraMax 400.
The aim is a held-out mean hue error of 6° or less per scanner and film type.

## Summary

| Scanner | Type | Split | Frames | Direct scan | Hand-set look | Fitted look | Aim |
|---|---|---|---|---|---|---|---|
| frontier | bw | held out | 4 | n/a | – / 7.6 | – / 4.9 |  |
| frontier | bw | training | 4 | n/a | – / 7.8 | – / 3.0 |  |
| frontier | colour_negative | held out | 20 | n/a | 18.3° / 9.4 | 11.1° / 4.8 | **missed** |
| frontier | colour_negative | training | 12 | n/a | 18.0° / 9.5 | 11.6° / 4.6 |  |
| frontier | slide | held out | 3 | 24.0° / 9.4 | 24.8° / 7.9 | 26.4° / 6.9 | **missed** |
| frontier | slide | training | 4 | 29.4° / 5.2 | 17.3° / 6.9 | 19.6° / 6.3 |  |
| noritsu | bw | held out | 4 | n/a | – / 6.6 | – / 6.2 |  |
| noritsu | bw | training | 4 | n/a | – / 6.8 | – / 3.6 |  |
| noritsu | colour_negative | held out | 20 | n/a | 16.6° / 8.1 | 13.8° / 4.7 | **missed** |
| noritsu | colour_negative | training | 12 | n/a | 13.6° / 7.7 | 14.0° / 4.4 |  |
| noritsu | slide | held out | 3 | 29.4° / 11.3 | 39.1° / 8.0 | 38.0° / 6.6 | **missed** |
| noritsu | slide | training | 4 | 32.6° / 7.6 | 17.8° / 6.6 | 19.7° / 5.1 |  |

## How far apart the real scans are

The same metric between real scans, as a floor for the numbers above.

| Type | Frontier vs Noritsu, same frame | 0 vs +1 EV, same film and scanner |
|---|---|---|
| colour_negative | 12.1° | 4.4° |
| slide | 11.1° | 11.9° |

## Grey wedge

Largest OKLab chroma ×100 of the chart's neutrals through the fitted look, −6 to +6 EV
(B&W: spread around its own tint).

| Film | Frontier | Noritsu |
|---|---|---|
| Kodak Portra 160 | 3.1 | 2.1 |
| Kodak Portra 400 | 2.6 | 1.9 |
| Kodak Portra 800 | 2.4 | 2.7 |
| Kodak Ektar 100 | 4.0 | 2.8 |
| Kodak Gold 200 | 2.4 | 1.9 |
| Kodak UltraMax 400 | 2.5 | 2.6 |
| Fujifilm C200 | 5.2 | 7.0 |
| Fujifilm Pro 400H | 2.1 | 2.4 |
| Fujifilm Provia 100F | 3.1 | 3.4 |
| Kodak Ektachrome E100 | 3.9 | 4.8 |
| Kodak TRI-X 400 | 0.2 | 0.0 |
| Kodak Eastman Double-X 5222 | 0.2 | 0.0 |

## Every frame

| Scanner | Film | EV | Held out | Direct | Hand-set | Fitted |
|---|---|---|---|---|---|---|
| frontier | Fujifilm C200 | +0EV |  | n/a | 16.1° / 11.2 | 19.5° / 5.0 |
| frontier | Fujifilm C200 | +1EV |  | n/a | 19.1° / 10.8 | 14.1° / 4.2 |
| frontier | Fujifilm C200 | +2EV | yes | n/a | 17.5° / 10.1 | 11.1° / 3.9 |
| frontier | Fujifilm C200 | -1EV | yes | n/a | 11.5° / 11.2 | 14.4° / 5.6 |
| frontier | Fujifilm Pro 400H | +0EV |  | n/a | 17.9° / 9.2 | 9.3° / 3.0 |
| frontier | Fujifilm Pro 400H | +1EV |  | n/a | 15.7° / 8.9 | 8.5° / 2.9 |
| frontier | Fujifilm Pro 400H | +2EV | yes | n/a | 15.3° / 8.9 | 7.6° / 2.9 |
| frontier | Fujifilm Pro 400H | -1EV | yes | n/a | 16.9° / 9.6 | 8.9° / 3.5 |
| frontier | Kodak Ektar 100 | +0EV |  | n/a | 16.9° / 9.8 | 8.2° / 4.3 |
| frontier | Kodak Ektar 100 | +1EV |  | n/a | 20.7° / 9.7 | 10.6° / 5.1 |
| frontier | Kodak Ektar 100 | +2EV | yes | n/a | 21.5° / 9.8 | 11.1° / 4.7 |
| frontier | Kodak Ektar 100 | -1EV | yes | n/a | 21.3° / 9.9 | 10.9° / 4.7 |
| frontier | Kodak Gold 200 | +0EV |  | n/a | 18.2° / 8.8 | 23.1° / 5.0 |
| frontier | Kodak Gold 200 | +1EV |  | n/a | 13.5° / 7.7 | 6.4° / 4.7 |
| frontier | Kodak Gold 200 | +2EV | yes | n/a | 15.3° / 7.1 | 6.1° / 5.8 |
| frontier | Kodak Gold 200 | -1EV | yes | n/a | 21.0° / 10.5 | 26.8° / 4.5 |
| frontier | Kodak Portra 160 | +0EV |  | n/a | 17.4° / 9.3 | 8.4° / 4.4 |
| frontier | Kodak Portra 160 | +1EV |  | n/a | 24.3° / 9.2 | 7.7° / 5.5 |
| frontier | Kodak Portra 160 | +2EV | yes | n/a | 26.6° / 9.9 | 11.2° / 5.1 |
| frontier | Kodak Portra 160 | -1EV | yes | n/a | 13.2° / 9.9 | 8.4° / 5.9 |
| frontier | Kodak Portra 400 | +0EV |  | n/a | 15.6° / 10.1 | 11.7° / 5.6 |
| frontier | Kodak Portra 400 | +1EV |  | n/a | 21.1° / 9.8 | 11.7° / 5.1 |
| frontier | Kodak Portra 400 | +2EV | yes | n/a | 18.4° / 10.2 | 9.7° / 5.1 |
| frontier | Kodak Portra 400 | -1EV | yes | n/a | 15.9° / 10.7 | 16.1° / 5.4 |
| frontier | Kodak Portra 800 | +0EV | yes | n/a | 25.1° / 9.5 | 11.9° / 4.8 |
| frontier | Kodak Portra 800 | +1EV | yes | n/a | 21.4° / 9.1 | 11.3° / 4.6 |
| frontier | Kodak Portra 800 | +2EV | yes | n/a | 18.5° / 8.8 | 11.6° / 4.3 |
| frontier | Kodak Portra 800 | -1EV | yes | n/a | 20.2° / 9.0 | 15.9° / 5.5 |
| frontier | Kodak UltraMax 400 | +0EV | yes | n/a | 15.4° / 9.1 | 6.7° / 4.3 |
| frontier | Kodak UltraMax 400 | +1EV | yes | n/a | 17.4° / 8.5 | 6.5° / 4.8 |
| frontier | Kodak UltraMax 400 | +2EV | yes | n/a | 18.9° / 8.4 | 6.9° / 5.9 |
| frontier | Kodak UltraMax 400 | -1EV | yes | n/a | 15.5° / 8.9 | 8.4° / 4.2 |
| frontier | Fujifilm Provia 100F | +0EV |  | 16.4° / 6.0 | 20.5° / 6.6 | 20.8° / 6.7 |
| frontier | Fujifilm Provia 100F | +1EV |  | 31.6° / 3.8 | 8.1° / 4.4 | 10.8° / 4.8 |
| frontier | Fujifilm Provia 100F | -1EV | yes | 20.6° / 10.2 | 20.8° / 8.1 | 20.8° / 8.0 |
| frontier | Fujifilm Provia 100F | -2EV | yes | 29.5° / 12.2 | 20.2° / 8.4 | 22.0° / 8.1 |
| frontier | Kodak Ektachrome E100 | +0EV |  | 41.9° / 5.1 | 22.8° / 9.7 | 27.5° / 8.9 |
| frontier | Kodak Ektachrome E100 | +1EV |  | 27.8° / 5.9 | 17.9° / 6.8 | 19.5° / 4.9 |
| frontier | Kodak Ektachrome E100 | +2EV | yes | 21.9° / 5.7 | 33.3° / 7.0 | 36.3° / 4.6 |
| frontier | Kodak Ektachrome E100 | -1EV | yes | chart not found | | |
| frontier | Kodak Eastman Double-X 5222 | +0EV |  | n/a | nan° / 8.8 | nan° / 3.1 |
| frontier | Kodak Eastman Double-X 5222 | +1EV |  | n/a | nan° / 7.3 | nan° / 2.5 |
| frontier | Kodak Eastman Double-X 5222 | +2EV | yes | n/a | nan° / 5.9 | nan° / 3.1 |
| frontier | Kodak Eastman Double-X 5222 | -1EV | yes | n/a | nan° / 9.3 | nan° / 6.4 |
| frontier | Kodak TRI-X 400 | +0EV |  | n/a | nan° / 8.1 | nan° / 3.2 |
| frontier | Kodak TRI-X 400 | +1EV |  | n/a | nan° / 7.2 | nan° / 3.3 |
| frontier | Kodak TRI-X 400 | +2EV | yes | n/a | nan° / 6.5 | nan° / 4.1 |
| frontier | Kodak TRI-X 400 | -1EV | yes | n/a | nan° / 8.7 | nan° / 5.9 |
| noritsu | Fujifilm C200 | +0EV |  | n/a | 17.6° / 10.4 | 28.4° / 5.6 |
| noritsu | Fujifilm C200 | +1EV |  | n/a | 19.2° / 9.8 | 16.8° / 4.7 |
| noritsu | Fujifilm C200 | +2EV | yes | n/a | 14.3° / 9.1 | 11.6° / 4.1 |
| noritsu | Fujifilm C200 | -1EV | yes | n/a | 27.3° / 9.8 | 23.2° / 4.7 |
| noritsu | Fujifilm Pro 400H | +0EV |  | n/a | 11.1° / 9.1 | 9.2° / 4.4 |
| noritsu | Fujifilm Pro 400H | +1EV |  | n/a | 9.8° / 8.4 | 7.7° / 4.0 |
| noritsu | Fujifilm Pro 400H | +2EV | yes | n/a | 9.3° / 8.9 | 7.4° / 4.1 |
| noritsu | Fujifilm Pro 400H | -1EV | yes | n/a | 23.8° / 9.2 | 13.7° / 4.4 |
| noritsu | Kodak Ektar 100 | +0EV |  | n/a | 11.0° / 6.1 | 9.2° / 3.7 |
| noritsu | Kodak Ektar 100 | +1EV |  | n/a | 22.1° / 7.2 | 20.5° / 5.6 |
| noritsu | Kodak Ektar 100 | +2EV | yes | n/a | 40.2° / 8.1 | 24.0° / 8.1 |
| noritsu | Kodak Ektar 100 | -1EV | yes | n/a | 10.5° / 8.8 | 9.7° / 4.6 |
| noritsu | Kodak Gold 200 | +0EV |  | n/a | 12.4° / 6.3 | 18.9° / 3.5 |
| noritsu | Kodak Gold 200 | +1EV |  | n/a | 17.0° / 6.0 | 13.0° / 3.6 |
| noritsu | Kodak Gold 200 | +2EV | yes | n/a | 16.9° / 5.8 | 10.9° / 5.0 |
| noritsu | Kodak Gold 200 | -1EV | yes | n/a | 15.8° / 8.3 | 21.5° / 3.6 |
| noritsu | Kodak Portra 160 | +0EV |  | n/a | 10.0° / 6.8 | 9.6° / 3.6 |
| noritsu | Kodak Portra 160 | +1EV |  | n/a | 10.3° / 6.0 | 8.4° / 5.2 |
| noritsu | Kodak Portra 160 | +2EV | yes | n/a | 14.8° / 6.0 | 11.6° / 4.0 |
| noritsu | Kodak Portra 160 | -1EV | yes | n/a | 15.2° / 8.1 | 21.9° / 4.1 |
| noritsu | Kodak Portra 400 | +0EV |  | n/a | 11.9° / 9.3 | 13.1° / 5.4 |
| noritsu | Kodak Portra 400 | +1EV |  | n/a | 11.2° / 7.5 | 12.7° / 4.0 |
| noritsu | Kodak Portra 400 | +2EV | yes | n/a | 10.4° / 7.1 | 10.7° / 3.5 |
| noritsu | Kodak Portra 400 | -1EV | yes | n/a | 15.6° / 12.3 | 24.3° / 7.1 |
| noritsu | Kodak Portra 800 | +0EV | yes | n/a | 12.7° / 7.0 | 10.0° / 4.0 |
| noritsu | Kodak Portra 800 | +1EV | yes | n/a | 12.5° / 6.5 | 12.0° / 4.6 |
| noritsu | Kodak Portra 800 | +2EV | yes | n/a | 15.2° / 5.8 | 11.0° / 4.8 |
| noritsu | Kodak Portra 800 | -1EV | yes | n/a | 17.7° / 9.7 | 16.3° / 5.4 |
| noritsu | Kodak UltraMax 400 | +0EV | yes | n/a | 11.1° / 8.0 | 9.3° / 4.8 |
| noritsu | Kodak UltraMax 400 | +1EV | yes | n/a | 11.0° / 7.2 | 8.7° / 4.6 |
| noritsu | Kodak UltraMax 400 | +2EV | yes | n/a | 11.5° / 7.2 | 8.3° / 4.6 |
| noritsu | Kodak UltraMax 400 | -1EV | yes | n/a | 25.4° / 9.5 | 10.0° / 4.8 |
| noritsu | Fujifilm Provia 100F | +0EV |  | 18.9° / 10.0 | 17.2° / 6.8 | 13.3° / 5.0 |
| noritsu | Fujifilm Provia 100F | +1EV |  | 13.2° / 6.1 | 8.3° / 5.4 | 11.6° / 4.6 |
| noritsu | Fujifilm Provia 100F | -1EV | yes | 31.5° / 13.3 | 37.6° / 8.3 | 35.9° / 7.0 |
| noritsu | Fujifilm Provia 100F | -2EV | yes | 28.8° / 12.9 | 38.8° / 7.8 | 35.9° / 7.4 |
| noritsu | Kodak Ektachrome E100 | +0EV |  | 51.4° / 7.7 | 23.2° / 8.0 | 20.0° / 6.0 |
| noritsu | Kodak Ektachrome E100 | +1EV |  | 47.0° / 6.8 | 22.3° / 6.1 | 33.7° / 4.7 |
| noritsu | Kodak Ektachrome E100 | +2EV | yes | 27.9° / 7.7 | 40.9° / 7.9 | 42.2° / 5.3 |
| noritsu | Kodak Ektachrome E100 | -1EV | yes | chart not found | | |
| noritsu | Kodak Eastman Double-X 5222 | +0EV |  | n/a | nan° / 7.3 | nan° / 3.1 |
| noritsu | Kodak Eastman Double-X 5222 | +1EV |  | n/a | nan° / 6.5 | nan° / 3.1 |
| noritsu | Kodak Eastman Double-X 5222 | +2EV | yes | n/a | nan° / 3.4 | nan° / 5.9 |
| noritsu | Kodak Eastman Double-X 5222 | -1EV | yes | n/a | nan° / 8.3 | nan° / 5.5 |
| noritsu | Kodak TRI-X 400 | +0EV |  | n/a | nan° / 6.5 | nan° / 4.0 |
| noritsu | Kodak TRI-X 400 | +1EV |  | n/a | nan° / 6.7 | nan° / 4.4 |
| noritsu | Kodak TRI-X 400 | +2EV | yes | n/a | nan° / 4.9 | nan° / 6.7 |
| noritsu | Kodak TRI-X 400 | -1EV | yes | n/a | nan° / 9.8 | nan° / 6.8 |
