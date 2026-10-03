---
source: https://help.synology.com/developer-guide/appendix/ui_framework/button.html
title: Button
fetched: 2026-09-11
---

# Button

## Template

`<v-button />`

## Button API

### Button - Props

``

``

****````

``````````````````````````

``````

``````````````

``````

****

****``********

``````````````````

****

``

``````````````````

``

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| subscribeField | Subscribe specific register-key form-item on ancestor | string | - | void 0 |  |  |
| activeFormItem | do not register on form-item | boolean | - | true |  |  |
| enterKey | used for enterkeyhint attribute, and will change behavior when enter key is pressed | string | - | EnterHint.Enter |  |  |
| boundaryComponentName | - | string | - | 'PortalTarget' |  |  |
| iconType | - | string | - | ICON_TYPE.FOLLOW_MANAGER |  |  |
| type | Button type.Note: split type only works when the dropdown slot is not empty. | string | '', 'footbar', 'dropdown', 'styleless', 'split', 'border', 'border-dropdown', 'border-split', 'footbar-border', 'footbar-border-dropdown', 'welcome', 'round', 'round-border' | '' |  |  |
| size | - | string | - | SIZE.NORMAL |  |  |
| display | Button display type. | string | 'text', 'icon', 'icon-text' | 'text' |  |  |
| suffix | Define the button custom suffix class | string | 'grey', 'blue', 'cancel', 'main', 'green', 'red', 'orange' | 'grey' |  |  |
| htmlType | htmlType of the button | string | 'submit', 'button', 'reset' | 'button' |  |  |
| disabled | If true, the button will be disabled. | boolean | - | false |  |  |
| icon | Class name the button's icon will have. | string | - | void 0 |  |  |
| menuAlign | Describe how the dropdown menu should be aligned to the button.Example: tl-&gt;bl means the top-left side of the menu will be stuck to the bottom-left side of the button. | string | 'c', 't', 'b', 'l', 'r', 'tl', 'tr', 'bl', 'br' | 'tl->bl' |  |  |
| menuConstrainHeight | when menu height is out of popup container, it will contrain menu to fixed height | boolean | - | false |  |  |
| tooltip | Text for the button's tooltip.If false, will disable it. | object\ | string\ | boolean | - | false |
| dropdownOffset | Dropdown menu's position offset | array | - | [0, 1] |  |  |
| useBreakpoint | - | boolean | - | true |  |  |
| name | Will use this name on breakpoints button group | string | - | '' |  |  |
| mobileBreakpoint | Assign the breakpoint of button.Less or equal than the breakpoint you assigned, mobile class would be added to the button's class list. | string\ | boolean | 'xxxl', 'xxl', 'xl', 'lg', 'md', 'sm', 'xs', 'xxs', 'xxxs' | 'xxs' |  |
| active | Only works in button-group, it will turns to active state when you pass true | boolean | - | false |  |  |
| getExtraElements | customize extra elements for prevent click outside | func | - | void 0 |  |  |

### Button - Methods

### handleClick

Method to handle click behavior.

| Param name | Type | Description |
|---|---|---|
| evt | EventObject | - |

### setPressed

Remove menuContainer in this hook (if menuConatiner is created).

| Param name | Type | Description |
|---|---|---|
| pressed | - | - |

### Button - Events

****``

****``

****``

****``

****``

| Event name | Properties | Description |
|---|---|---|
| focus-next-field | - | - |
| focus-prev-field | - | - |
| blur | - | - |
| dropdown-show | value Boolean - show/hide of the dropdown | Emitted when the dropdown menu is opened/closed. |
| dropdown-open | value Boolean - open/close of the dropdown | Emitted when dropdown menu is opened |
| dropdown-close | value Boolean - open/close of the dropdown | Emitted when dropdown menu is closed |
| click | evt EventObject - the click event object | Emitted when button is clicked. |
| click-dropdown | item Object - undefined | Emitted when the overflow toolbar item has been clicked |

### Button - Slots

``

``

| Name | Description | Bindings |
|---|---|---|
| icon | icon inside &lt;v-button&gt; | - |
| default | content inside &lt;v-button&gt; | - |
| dropdown | Dropdown content | - |
