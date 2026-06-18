@echo off
REM Edit these paths if needed.
set Q3_ROOT=C:\q3
set RTX_ROOT=C:\q3\rtx-remix
set TXRMAP=docs\txrmap.txt
set OUT=visual_match_out

py -m pip install pillow requests
py scripts\lmstudio_visual_material_match.py --q3-root "%Q3_ROOT%" --rtx-root "%RTX_ROOT%" --txrmap "%TXRMAP%" --out "%OUT%" --prepare

echo.
echo Start LM Studio Local Server with a VISION model, then run:
echo py scripts\lmstudio_visual_material_match.py --q3-root "%Q3_ROOT%" --rtx-root "%RTX_ROOT%" --txrmap "%TXRMAP%" --out "%OUT%" --match --max-items 20 --max-sheets 10
echo.
