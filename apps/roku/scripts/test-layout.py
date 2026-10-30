"""Layout arithmetic for the 1920x1080 scene. Nothing here renders SceneGraph; it checks the numbers
the scene and the card shapes are built from: safe margins, type sizes, overlaps and card ratios."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CHANNEL = ROOT / 'channel'
SCREEN_W, SCREEN_H = 1920, 1080
SAFE_X0, SAFE_X1, SAFE_Y0, SAFE_Y1 = 96, 1824, 54, 1026

scene = ET.parse(CHANNEL / 'components/ReelScene.xml').getroot()
scene_brs = (CHANNEL / 'components/ReelScene.brs').read_text()
format_brs = (CHANNEL / 'source/Format.brs').read_text()


def vector(text):
    return [float(v) for v in re.findall(r'-?\d+(?:\.\d+)?', text or '')]


def box(node, parent_origin=(0, 0)):
    x, y = (vector(node.attrib.get('translation', '[0,0]')) + [0, 0])[:2]
    return (parent_origin[0] + x, parent_origin[1] + y,
            float(node.attrib.get('width', 0)), float(node.attrib.get('height', 0)))


nodes = {}


def walk(parent, origin):
    for child in parent:
        if child.tag in {'Font', 'FloatFieldInterpolator'}:
            continue
        x, y, w, h = box(child, origin)
        if 'id' in child.attrib:
            nodes[child.attrib['id']] = {'tag': child.tag, 'x': x, 'y': y, 'w': w, 'h': h, 'node': child}
        if child.tag == 'Group':
            walk(child, (x, y))
        else:
            walk(child, origin)


walk(scene.find('children'), (0, 0))
failures = []


def check(name, ok, detail=''):
    if not ok:
        failures.append(f'{name} {detail}'.strip())


def font_size(node):
    font = node.find('Font')
    return float(font.attrib['size']) if font is not None else None


# 1. Text stays inside the title-safe area and is large enough to read from a couch.
for name, entry in nodes.items():
    if entry['tag'] != 'Label':
        continue
    size = font_size(entry['node'])
    check(f'{name} has a declared font size', size is not None)
    if size is None:
        continue
    check(f'{name} text is at least 24px', size >= 24, f'size {size}')
    check(f'{name} left margin', entry['x'] >= SAFE_X0, f'x {entry["x"]}')
    check(f'{name} right margin', entry['x'] + entry['w'] <= SAFE_X1 + 0.5 or name.startswith('episodePanel'), f'right {entry["x"] + entry["w"]}')
    check(f'{name} top margin', entry['y'] >= SAFE_Y0, f'y {entry["y"]}')
    check(f'{name} bottom margin', entry['y'] + entry['h'] <= SAFE_Y1, f'bottom {entry["y"] + entry["h"]}')
check('title size near the other TV clients (56 to 72)', 56 <= font_size(nodes['title']['node']) <= 72)
check('row labels near 32px', 30 <= float(nodes['rows']['node'].find('Font').attrib['size']) <= 34)

# 2. Full-bleed layers cover the screen; the player fills it.
for name in ['backdropBack', 'backdropFront', 'video']:
    entry = nodes[name]
    check(f'{name} fills the screen', (entry['x'], entry['y'], entry['w'], entry['h']) == (0, 0, SCREEN_W, SCREEN_H))

# 3. Tab bar: estimated width, centred, clear of the brand mark and the account text.
labels = re.search(r'm\.nav\.labels = \[([^\]]*)\]', scene_brs).group(1)
tabs = re.findall(r'"([^"]+)"', labels)
check('five tabs', tabs == ['Home', 'Movies', 'Series', 'Search', 'Settings'], str(tabs))
pill_brs = (CHANNEL / 'components/PillRow.brs').read_text()
height, padding, gap = [int(v) for v in re.search(r'if style = "tabs" then return \{height: (\d+), padding: (\d+), gap: (\d+)', pill_brs).groups()]
nav_width = sum(len(t) * 17 + padding * 2 for t in tabs) + gap * (len(tabs) - 1) + 12
nav_left = (SCREEN_W - nav_width) / 2
check('the wordmark sits right of the mark', nodes['wordmark']['x'] >= nodes['brand']['x'] + nodes['brand']['w'], f'x {nodes["wordmark"]["x"]}')
check('tab bar clears the wordmark', nav_left > nodes['wordmark']['x'] + nodes['wordmark']['w'] + 24, f'left {nav_left}')
check('tab bar clears the account text', nav_left + nav_width < nodes['accountLabel']['x'], f'right {nav_left + nav_width}')
check('tab bar inside the top safe margin', nodes['nav']['y'] >= SAFE_Y0)
check('tab pill is a comfortable target', height >= 60)
nav_centre = nodes['nav']['y'] + (height + 2 * int(re.search(r'if style = "tabs" then return \{[^}]*inset: (\d+)', pill_brs).group(1))) / 2
for name in ['brand', 'wordmark', 'accountLabel', 'optionsFill']:
    centre = nodes[name]['y'] + nodes[name]['h'] / 2
    check(f'{name} is centred on the tab bar', abs(centre - nav_centre) <= 2, f'centre {centre}, tab bar {nav_centre}')
narrow = int(re.search(r'if hasOptions then account\.width = (\d+)', scene_brs).group(1))
check('the account line ends before the Options capsule', nodes['accountLabel']['x'] + narrow + 16 <= nodes['optionsFill']['x'], f'ends {nodes["accountLabel"]["x"] + narrow}')
check('the Options capsule is a 9-patch pill at its own height', nodes['optionsFill']['h'] >= 60)
button_height = int(re.search(r'^    return \{height: (\d+), padding: \d+, gap: \d+, minWidth', pill_brs, re.M).group(1))
check('buttons are capsules', re.search(r'^    return \{height: \d+[^}]*fill: "pkg:/images/fill-pill\.9\.png"\}', pill_brs, re.M) is not None)

# 4. Card shapes: posters 2:3, wide cards 16:9, rows stack inside the screen.
spec = {}
for shape in ['wide', 'poster', 'season']:
    if shape == 'poster':
        line = re.search(r'^    return \{width: (\d+), height: (\d+), gap: (\d+), label: (\d+), after: (\d+)', format_brs, re.M)
    else:
        line = re.search(r'if shape = "%s" then return \{width: (\d+), height: (\d+), gap: (\d+), label: (\d+), after: (\d+)' % shape, format_brs)
    spec[shape] = dict(zip(['width', 'height', 'gap', 'label', 'after'], [int(v) for v in line.groups()]))
    rest = format_brs[line.end():format_brs.index('\n', line.end())]
    spec[shape]['labelGap'] = int(re.search(r'labelGap: (\d+)', rest).group(1))
check('poster ratio is 2:3', abs(spec['poster']['height'] / spec['poster']['width'] - 1.5) < 0.02)
check('season ratio is 2:3', abs(spec['season']['height'] / spec['season']['width'] - 1.5) < 0.02)
check('wide ratio is 16:9', abs(spec['wide']['width'] / spec['wide']['height'] - 16 / 9) < 0.02)
content_width = SAFE_X1 - SAFE_X0
per_row = int(re.search(r'perRow = (\d+)', scene_brs).group(1))
check(f'{per_row} posters fit a library row', per_row * spec['poster']['width'] + (per_row - 1) * spec['poster']['gap'] <= content_width)
check('four wide cards fit a row', 4 * spec['wide']['width'] + 3 * spec['wide']['gap'] <= content_width)
card_brs = (CHANNEL / 'components/ReelCard.brs').read_text()
detail_y = int(re.search(r'm\.subtitle\.translation = \[0, h \+ (\d+)\]', card_brs).group(1))
detail_h = int(re.search(r'm\.subtitle\.height = (\d+)', card_brs).group(1))
focus_scale = 1 + float(re.search(r'scale = 1 \+ ([\d.]+) \* percent', card_brs).group(1))
ring_out = -int(re.search(r'm\.ring\.translation = \[(-?\d+), (-?\d+)\]', card_brs).group(2))
row_label_size = float(nodes['rows']['node'].find('Font').attrib['size'])
check('showRows spaces labels by the shape spec', 'offsets.push([0, spec.labelGap])' in scene_brs)
check('the RowList default label gap matches the wide spec', vector(nodes['rows']['node'].attrib['rowLabelOffset'])[1] == spec['wide']['labelGap'])
ring_rise = {}
for shape, s in spec.items():
    # The focus scale grows the card, its ring and its captions around the card's centre.
    caption_end = (s['height'] / 2 + detail_y + detail_h) * focus_scale - s['height'] / 2
    check(f'focused {shape} caption clears the next row by 8 px', caption_end + 8 <= s['after'], f'ends {caption_end:.1f} px under the card, after is {s["after"]}')
    ring_rise[shape] = (s['height'] / 2 + ring_out) * focus_scale - s['height'] / 2
    check(f'focused {shape} ring clears the row label by 8 px', ring_rise[shape] + 8 <= s['labelGap'], f'ring rises {ring_rise[shape]:.1f} px, label gap is {s["labelGap"]}')
    check(f'{shape} label band holds the label line and its gap', s['label'] >= s['labelGap'] + row_label_size * 1.15, f'band {s["label"]}')

# 5. Title block layouts from RKScreenLayout: no overlaps in any mode, and Details leaves room for
# buttons and seasons. Line heights assume about 1.15 x the font size, which Roku does not publish.
screen = {mode: {k: int(v) for k, v in re.findall(r'(\w+): (-?\d+)', body)}
          for mode, body in re.findall(r'if mode = "(\w+)" then return \{([^}]*)\}', format_brs)}
screen['list'] = {k: int(v) for k, v in re.findall(r'(\w+): (-?\d+)', re.search(r'function RKScreenLayout.*?\n    return \{([^}]*)\}', format_brs, re.S).group(1))}
check('six screen layouts', sorted(screen) == ['details', 'feature', 'grid', 'hero', 'list', 'message'], str(sorted(screen)))
title_size = font_size(nodes['title']['node'])
description_size = font_size(nodes['description']['node'])
description_spacing = float(nodes['description']['node'].attrib.get('lineSpacing', 0))
for mode, s in screen.items():
    for key in ['title', 'meta', 'genres', 'description', 'rows', 'buttons', 'actions']:
        check(f'{mode}: {key} is on the 8 px grid', s[key] == -1 or s[key] % 8 == 0, str(s[key]))
    check(f'{mode}: title lines fit', s['titleLines'] * title_size * 1.15 <= s['titleHeight'])
    check(f'{mode}: overview lines fit', s['descriptionLines'] * description_size * 1.15 + (s['descriptionLines'] - 1) * description_spacing <= s['descriptionHeight'])
    items = [('title', s['title'], s['title'] + s['titleHeight'])]
    for name, height in [('meta', nodes['meta']['h']), ('genres', nodes['genres']['h']), ('description', s['descriptionHeight'])]:
        if s[name] >= 0 and not (mode == 'grid' and name == 'description'):
            items.append((name, s[name], s[name] + height))
    items.sort(key=lambda t: t[1])
    for (a, _, a_end), (b, b_start, _) in zip(items, items[1:]):
        check(f'{mode}: {a} does not overlap {b}', a_end <= b_start, f'{a} ends {a_end}, {b} starts {b_start}')
    check(f'{mode}: title block clears the status line', items[0][1] >= nodes['status']['y'] + nodes['status']['h'])
    s['textEnd'] = items[-1][2]

hero, details, feature, grid, listing, message = (screen[m] for m in ['hero', 'details', 'feature', 'grid', 'list', 'message'])
check('home rows sit below the overview', hero['rows'] >= hero['textEnd'] + 24, f'{hero["textEnd"]} vs {hero["rows"]}')
check('home Play and Details sit below the overview', hero['buttons'] >= hero['textEnd'] + 16, f'{hero["textEnd"]} vs {hero["buttons"]}')
check('home rows sit below Play and Details', hero['rows'] >= hero['buttons'] + button_height + 24, f'{hero["buttons"]} vs {hero["rows"]}')
# A movie or episode sets its title block low: buttons under the overview, a focused button (1.05) inside
# the bottom safe edge, and the block in the lower half where the bottom scrim darkens the art.
button_focus = float(re.search(r'if isFocus then cell\.group\.scale = \[([\d.]+),', pill_brs).group(1))
check('feature buttons sit below the overview', feature['buttons'] >= feature['textEnd'] + 24, f'{feature["textEnd"]} vs {feature["buttons"]}')
feature_bottom = feature['buttons'] + button_height / 2 + button_height * button_focus / 2
check('a focused feature button stays inside the safe area', feature_bottom <= SAFE_Y1, f'bottom {feature_bottom}')
check('the feature title block sits on the bottom scrim', feature['genres'] >= nodes['scrimBottom']['y'] + 120, f'starts {feature["genres"]}')
for mode in ['hero', 'details', 'feature']:
    check(f'{mode}: the genre eyebrow sits directly above the title', screen[mode]['genres'] + nodes['genres']['h'] == screen[mode]['title'], f'{screen[mode]["genres"]} vs {screen[mode]["title"]}')
check('home rows start near the middle', hero['rows'] + spec['wide']['label'] >= SCREEN_H / 2, f'cards start {hero["rows"] + spec["wide"]["label"]}')
for shape in ['wide', 'poster']:
    bottom = hero['rows'] + spec[shape]['label'] + spec[shape]['height'] + spec[shape]['after']
    check(f'a focused {shape} row on Home fits with its caption', bottom <= SAFE_Y1, f'bottom {bottom}')
peek = hero['rows'] + spec['wide']['label'] + spec['wide']['height'] + spec['wide']['after'] + spec['poster']['label']
check('the next Home row shows its label above the safe edge', peek <= SAFE_Y1, f'label ends {peek}')
check('details buttons sit below the overview', details['textEnd'] <= details['buttons'], f'{details["textEnd"]} vs {details["buttons"]}')
check('season row sits below the buttons', details['rows'] >= details['buttons'] + button_height + 24)
season_bottom = details['rows'] + spec['season']['label'] + spec['season']['height'] + spec['season']['after']
check('season row and its caption fit the safe area', season_bottom <= SAFE_Y1, f'bottom {season_bottom}')
check('grid rows start below the title', grid['rows'] >= grid['textEnd'])
grid_title = re.search(r'rows = collectionRows\(m\.items, "([^"]*)"', scene_brs).group(1)
grid_label = spec['poster']['label'] if grid_title else 0
if not grid_title:
    check('an unlabelled grid row keeps its focus ring off the title block', grid['rows'] - ring_rise['poster'] >= grid['textEnd'] + 8, f'ring top {grid["rows"] - ring_rise["poster"]:.1f}, text ends {grid["textEnd"]}')
grid_second = grid['rows'] + grid_label + spec['poster']['height'] + spec['poster']['after'] + spec['poster']['height']
check('two poster rows show on a library page', grid_second <= SAFE_Y1, f'bottom {grid_second}')
actions = nodes['actions']['node']
item_h = vector(actions.attrib['itemSize'])[1]
list_bottom = listing['actions'] + int(actions.attrib['numRows']) * item_h + (int(actions.attrib['numRows']) - 1) * vector(actions.attrib['itemSpacing'])[1]
check('list sits below the overview', listing['actions'] >= listing['textEnd'])
check('a full list fits the safe area', list_bottom <= SAFE_Y1, f'bottom {list_bottom}')
check('message buttons sit below the message', message['buttons'] >= message['textEnd'] + 24)
check('message block sits near the middle', abs((message['title'] + message['buttons'] + button_height) / 2 - SCREEN_H / 2) <= 40)
icon = nodes['searchIcon']
check('the search glyph is centred over the message', icon['x'] + icon['w'] / 2 == SCREEN_W / 2, f'centre {icon["x"] + icon["w"] / 2}')
check('the search glyph sits above the message title', icon['y'] + icon['h'] + 16 <= message['title'], f'ends {icon["y"] + icon["h"]}')

# 6. UI copy never carries an em or en dash.
for path in sorted(CHANNEL.rglob('*')):
    if path.suffix in {'.brs', '.xml'}:
        text = path.read_text()
        check(f'{path.name} has no em or en dash', not re.search('[' + chr(0x2013) + chr(0x2014) + ']', text))

if failures:
    raise SystemExit('Layout checks failed:\n  ' + '\n  '.join(failures))
print('layout arithmetic checks passed; this does not render SceneGraph')
