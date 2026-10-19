from PIL import Image, ImageDraw

size = 1024
img = Image.new("RGBA", (size, size), "#0E7CF6")
d = ImageDraw.Draw(img)

# Rounded inner card
pad = 120
d.rounded_rectangle((pad, pad, size - pad, size - pad), radius=180, fill="#EAF4FF")

# Shield
shield = [
    (size * 0.5, size * 0.24),
    (size * 0.72, size * 0.34),
    (size * 0.67, size * 0.63),
    (size * 0.5, size * 0.78),
    (size * 0.33, size * 0.63),
    (size * 0.28, size * 0.34),
]
d.polygon(shield, fill="#0E7CF6")

# White block mark
d.line((size * 0.39, size * 0.44, size * 0.61, size * 0.56), fill="white", width=42)
d.line((size * 0.61, size * 0.44, size * 0.39, size * 0.56), fill="white", width=42)

# Number 6 badge
badge_r = 112
cx, cy = int(size * 0.78), int(size * 0.78)
d.ellipse((cx - badge_r, cy - badge_r, cx + badge_r, cy + badge_r), fill="#FF5A6E")
d.text((cx - 30, cy - 45), "6", fill="white")

img.save("/Users/rogan/Desktop/appDev/6VPN_Image_Blocker/mobile/assets/launcher_icon_6vpn.png")
