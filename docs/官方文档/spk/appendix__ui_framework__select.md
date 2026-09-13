---
source: https://help.synology.com/developer-guide/appendix/ui_framework/select.html
title: Select Input API
fetched: 2026-09-11
---

> Select is a component which we can select one or multiple item.
> It can also be used as seach field or textfilter.
> **Must** use **v-model** to set/get its value.

`<v-single-select />` and `<v-multiple-select />`

## Select Input API

### Select Input - Props

****

****

``````

| Prop name | Description | Type | Values | Default |
|---|---|---|---|---|
| iconType | - | string | - | ICON_TYPE.FOLLOW_MANAGER |
| clearIconCls | - | array | - | [] |
| searchIconCls | - | array | - | [] |
| allowClear | - | boolean | - | false |
| allowEdit | - | boolean | - | false |
| value | - | string | - | '' |
| inputTooltip | - | object | - | disabled: true, |
| clearable | If true, there will be a clear button in the select. | boolean | - | false |
| hideTrigger | If true, the arrow-down icon at the right-side of the select will be hidden. | boolean | - | undefined |
| placeholder | The placeholder which will be shown when no option is selected. | string | - | '' |
| inputAttrs | - | object | - | () => {} |
| openDropdown | - | func | - | noop |
| toggleDropdown | - | func | - | noop |
| closeDropdown | - | func | - | noop |
| advanced | - | boolean | - | false |
| rightAdvanceIcon | - | boolean | - | false |
| displayField | - | string | - | 'label' |
| valueField | - | string | - | 'value' |
| triggerQueryAction | - | string | - | 'all' |
| autoOpenDropdownCharCount | - | number | - | -1 |
| toggleDropdownOnClick | - | boolean | - | true |
| mode | - | string | - | 'normal' |
| selectedOption | - | object | - | - |
| displayTextFormat | - | object | - | { key: void 0, group: '{group}:{option}', option: '{option}', delimiter: ',',} |
| displayMode | - | string | text, none, html | 'none' |
| groupOptions | - | object | - | - |
| enterKeyHint | - | string | - | void 0 |
| disabled | - | boolean | - | false |

### Select Input - Events

| Event name | Properties | Description |
|---|---|---|
| click-icon | - | - |
| click-advanced-icon | - | - |
| input | - | - |
| key-enter | - | - |
| key-esc | - | - |
| arrow-up | - | - |
| arrow-down | - | - |
| keydown | - | - |
| focus | - | - |
| blur | - | - |
| clear | - | - |

### Select Input - Slots

| Name | Description | Bindings |
|---|---|---|
| icon | - | - |
| clear-icon | Place to put your custom clear icon | - |
| dropdown-icon | Custom dropdown icon | - |
| right | custom search icon | - |

## Multiple Select Input API

### Multiple Select Input - Props

****

****

``````

| Prop name | Description | Type | Values | Default |  |
|---|---|---|---|---|---|
| iconType | - | string | - | ICON_TYPE.FOLLOW_MANAGER |  |
| clearIconCls | - | array | - | [] |  |
| searchIconCls | - | array | - | [] |  |
| allowClear | - | boolean | - | false |  |
| allowEdit | - | boolean | - | false |  |
| value | - | string | - | '' |  |
| inputTooltip | - | object | - | disabled: true, |  |
| clearable | If true, there will be a clear button in the select. | boolean | - | false |  |
| hideTrigger | If true, the arrow-down icon at the right-side of the select will be hidden. | boolean | - | undefined |  |
| placeholder | The placeholder which will be shown when no option is selected. | string | - | '' |  |
| inputAttrs | - | object | - | () => {} |  |
| openDropdown | - | func | - | noop |  |
| toggleDropdown | - | func | - | noop |  |
| closeDropdown | - | func | - | noop |  |
| advanced | - | boolean | - | false |  |
| rightAdvanceIcon | - | boolean | - | false |  |
| displayField | - | string | - | 'label' |  |
| valueField | - | string | - | 'value' |  |
| triggerQueryAction | - | string | - | 'all' |  |
| autoOpenDropdownCharCount | - | number | - | -1 |  |
| toggleDropdownOnClick | - | boolean | - | true |  |
| mode | - | string | - | 'normal' |  |
| selectedOption | - | object | - | - |  |
| displayTextFormat | - | object | - | { key: void 0, group: '{group}:{option}', option: '{option}', delimiter: ',',} |  |
| displayMode | - | string | text, none, html | 'label' |  |
| groupOptions | - | object | - | - |  |
| enterKeyHint | - | string | - | void 0 |  |
| disabled | - | boolean | - | false |  |
| selectedOptions | - | array | - | [] |  |
| getOptionTooltip | - | func | - | - |  |
| allowInvalidLabel | - | boolean | - | false |  |
| displayText | - | string\ | boolean | - | false |
| labelEditable | - | boolean | - | false |  |

### Multiple Select Input - Events

****``

| Event name | Properties | Description |
|---|---|---|
| click-icon | - | - |
| focus | - | - |
| blur | - | - |
| click-advanced-icon | - | - |
| input | - | - |
| key-enter | - | - |
| key-esc | - | - |
| arrow-up | - | - |
| arrow-down | - | - |
| keydown | - | - |
| clear | - | - |
| is-editing | - | - |
| item-removed | \<anonymous1\> undefined - undefined | - |
| reposition-menu | - | - |
| commit | - | - |
| focus-out | - | - |
| focus-in | - | - |
| editing-label-input | - | - |

### Multiple Select Input - Slots

| Name | Description | Bindings |
|---|---|---|
| icon | - | - |
| pre-label | - | - |
| clear-icon | Place to put your custom clear icon | - |
| dropdown-icon | Custom dropdown icon | - |
| right | custom search icon | - |

## Multiple Select API

### Multiple Select - Props

``

``

``

****

****

****
****

****``
****``********

****

``
``

****

****

****``

****

****

``````

````````

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| subscribeField | Subscribe specific register-key form-item on ancestor | string | - | void 0 |  |  |
| activeFormItem | do not register on form-item | boolean | - | true |  |  |
| enterKey | used for enterkeyhint attribute, and will change behavior when enter key is pressed | string | - | void 0 |  |  |
| boundaryComponentName | - | string | - | 'PortalTarget' |  |  |
| iconType | - | string | - | ICON_TYPE.FOLLOW_MANAGER |  |  |
| v-model | Selected option's value. | array | - | [] |  |  |
| id | id for this component. | string | - | function() { return syno-${this.uuid};} |  |  |
| name | Name for this select. | string | - | '' |  |  |
| width | The component's width. | number\ | string | - | 250 |  |
| maxHeight | Max height of the dropdown menu. | number\ | string | - | 200 |  |
| dropdownWidth | Dropdown menu's width. | string\ | number | - | void 0 |  |
| dropdownOffset | Dropdown menu's position offset | array | - | [0, 1] |  |  |
| customDropdownCls | Class names which the dropdown menu will have. | string | - | '' |  |  |
| disabled | If true, the select component will be disabled. | boolean | - | false |  |  |
| filter | Custom filter function which will be called when trigger search.If this prop is provided, the default filter function will be ignored.Type: `(display: string, currentOptions: Options[], queryAction: 'all' \ | 'keyword') => Options[]` | func | - | void 0 |  |
| search | If true, the select will become search component.See: 'Search' example. | func | - | undefined |  |  |
| align | How the dropdown menu should be aligned.Options: ['c', 't', 'b', 'l', 'r', 'tl', 'tr', 'bl', 'br'].Example: tl-&gt;bl means the top-left side of the menu will be stuck to the bottom-left side of the select. | string | - | 'tl->bl' |  |  |
| minSearchChar | The searching function of the component will be triggered only if the length of input-field's value is larger than this prop. | number\ | string | - | 1 |  |
| loadingText | Text which will be displayed when dropdown menu is loading. | string | - | function() { return this._i18n('uicommon', 'searching');} |  |  |
| notFoundText | The text which will be displayed when no item is found. | string | - | function () { return this._i18n('search', 'no_search_result');} |  |  |
| tooltip | If true, each item in the dropdown menu will have a tooltip. | boolean | - | false |  |  |
| mapOptionToTooltip | Map menu option to tooltip's content.It will be given a menu option as param and should return a string.If this prop is not provided, then the tooltip's content will be option's display field. | func | - | null |  |  |
| shouldMenuClose | A function will will be called before the dropdown menu close.If this function return true, then the dropdown menu won't be closed. | func | - | () => true |  |  |
| options | The function that generate options for the component.It can be an array with options too. | object\ | array | - | () => [] |  |
| groupOptions | when you use options as object, it will turns to use grouped options to displayand you can use this props to specify the group option to usefor example: if options has been given by { 'objKey': [{ label: 'Red', value: 'red' }] }and you can use groupOptions: { 'objKey': { label: 'Group String' } } to specify the display string | object | - | () => {} |  |  |
| clearable | If true, there will be a clear button in the select. | boolean | - | true |  |  |
| editable | Input text will be editable | boolean | - | true |  |  |
| hideTrigger | If true, the arrow-down icon at the right-side of the select will be hidden. | boolean | - | undefined |  |  |
| position | Positon strategy for the dropdown menu. | string | - | 'absolute' |  |  |
| displayField | Field name of option label | string | - | 'label' |  |  |
| valueField | Field name of option value | string | - | 'value' |  |  |
| closeOnSelect | Close dropdown menu when user click option | boolean | - | false |  |  |
| placeholder | The placeholder which will be shown when no option is selected. | string | - | '' |  |  |
| nullValue | The Null Value, use this value if you want to set select back to empty state | string\ | array | - | null |  |
| inputScrollable | - | boolean | - | false |  |  |
| inputTooltip | - | object | - | disabled: true, |  |  |
| useOptionSlot | - | boolean\ | string | - | void 0 |  |
| triggerQueryAction | The action to execute when the trigger is clicked. default is 'all'Options: ['all', 'keyword'] | string | - | 'all' |  |  |
| caseSensitive | If true, when the component is editable, the comparison will be case sensitive. | boolean | - | false |  |  |
| virtualScrollbar | If true, this component will use virtual scroll into dropdown | boolean | - | false |  |  |
| virtualItemHeight | virtual scroll info, item height of option | number | - | 28 |  |  |
| virtualBufferSize | Virtual Scroll buffer size | number | - | 200 |  |  |
| showNotFound | - | boolean | - | true |  |  |
| showDropdown | - | boolean | - | true |  |  |
| displayTextFormat | - | object | - | { group: '{group}:{option}', option: '{option}', delimiter: this._i18n('common', 'comma'),} |  |  |
| displayMode | labels display mode | string | label, text, none | 'label' |  |  |
| advanced | - | boolean\ | object | - | false |  |
| searchIconActive | true to distinguish advanced search conditions are set in advance panel.the search icon would separate in two parts, blue for search icon, grey for dropdown icon. | boolean | - | false |  |  |
| defaultOption | - | object\ | func\ | string | - | () => vCheckOption |
| customIcon | - | string | search, filter, custom, none | void 0 |  |  |
| hideSelected | Decide whether hide selected item, false to make selected item visible. | boolean | - | false |  |  |
| height | The component's height. | number\ | string | - | 'auto' |  |
| allowInvalidLabel | - | boolean | - | false |  |  |
| autoAddLabel | allow auto add label | boolean\ | object | - | false |  |
| editLabel | able to edit label which is selected | boolean | - | false |  |  |
| displayText | - | string\ | boolean | - | false |  |

### Multiple Select - Methods

### setLoading

show busy status on search dropdown

| Param name | Type | Description |
|---|---|---|
| status | boolean | - |

### Multiple Select - Events

****``

****``

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
| display-changed | - | - |
| dropdown-shown | undefined mixed - undefined | Emitted when dropdown shown. |
| dropdown-hidden | undefined mixed - undefined | Emitted when dropdown hidden. |
| is-active | isActive Boolean - undefined | Emitted when the select's active status is changed. |
| close-dropdown | - | - |
| click-icon | - | Emitted when icon is clicked. |
| click-advanced-icon | - | Emitted when right advanced icon is clicked. |
| clear | - | - |
| input | value Array - undefined | - |
| internal-select | index object - index of selected option | Triggers when the option is clicked. |
| select | opt object - selected option | Triggers when the option is clicked. |
| focus | - | - |
| item-removed | \<anonymous1\> undefined - undefined | - |

### Multiple Select - Slots

| Name | Description | Bindings |
|---|---|---|
| input | - |  |
| input-right | - | - |
| pre-label | - | - |
| default | - | - |

## Select Action Option API

### Select Action Option - Props

****

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| id | - | string | - | void 0 |  |  |
| option | - | object | - | - |  |  |
| display | - | string | - | void 0 |  |  |
| value | - | number\ | string\ | boolean | - | void 0 |
| selectable | - | boolean | - | true |  |  |
| disabled | - | boolean | - | false |  |  |
| activated | - | boolean | - | false |  |  |
| customClass | - | array\ | object\ | string | - | void 0 |
| isSelected | - | boolean | - | void 0 |  |  |
| tooltip | - | boolean\ | object | - | false |  |
| active | - | func | - | noop |  |  |
| hover | - | func | - | noop |  |  |
| hoverOut | - | func | - | noop |  |  |
| toggle | - | func | - | noop |  |  |
| customActiveBehavior | Custom active behavior, If true, it will activated only when passed props by activated="true", otherwise, hover and mouse-out will trigger activated or not | boolean | - | false |  |  |

### Select Action Option - Events

| Event name | Properties | Description |
|---|---|---|
| active | - | - |
| click | - | - |
| hover | - | - |
| mouseenter | - | - |
| hover-out | - | - |
| mouseleave | - | - |

### Select Action Option - Slots

| Name | Description | Bindings |
|---|---|---|
| inner-option | - | - |

## Select Check Option API

### Select Check Option - Props

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| id | - | string | - | void 0 |  |  |
| option | - | object | - | - |  |  |
| display | - | string | - | void 0 |  |  |
| value | - | number\ | string\ | boolean | - | void 0 |
| selectable | - | boolean | - | true |  |  |
| disabled | - | boolean | - | false |  |  |
| activated | - | boolean | - | false |  |  |
| customClass | - | array\ | object\ | string | - | void 0 |
| isSelected | - | boolean | - | void 0 |  |  |
| tooltip | - | boolean\ | object | - | false |  |
| active | - | func | - | noop |  |  |
| hover | - | func | - | noop |  |  |
| hoverOut | - | func | - | noop |  |  |
| toggle | - | func | - | noop |  |  |

### Select Check Option - Events

| Event name | Properties | Description |
|---|---|---|
| active | - | - |
| click | - | - |
| hover | - | - |
| mouseenter | - | - |
| hover-out | - | - |
| mouseleave | - | - |
| toggle | - | - |

### Select Check Option - Slots

| Name | Description | Bindings |
|---|---|---|
| inner-option | - | - |

## Select Divider Option API

### Select Divider Option - Props

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| id | - | string | - | void 0 |  |  |
| option | - | object | - | - |  |  |
| display | - | string | - | void 0 |  |  |
| value | - | number\ | string\ | boolean | - | void 0 |
| selectable | - | boolean | - | true |  |  |
| disabled | - | boolean | - | false |  |  |
| activated | - | boolean | - | false |  |  |
| customClass | - | array\ | object\ | string | - | void 0 |
| isSelected | - | boolean | - | void 0 |  |  |
| tooltip | - | boolean\ | object | - | false |  |
| active | - | func | - | noop |  |  |
| hover | - | func | - | noop |  |  |
| hoverOut | - | func | - | noop |  |  |
| toggle | - | func | - | noop |  |  |

### Select Divider Option - Events

| Event name | Properties | Description |
|---|---|---|
| active | - | - |
| click | - | - |
| hover | - | - |
| mouseenter | - | - |
| hover-out | - | - |
| mouseleave | - | - |

### Select Divider Option - Slots

| Name | Description | Bindings |
|---|---|---|
| inner-option | - | - |

## Select Group Option API

### Select Group Option - Props

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| id | - | string | - | void 0 |  |  |
| option | - | object | - | - |  |  |
| display | - | string | - | void 0 |  |  |
| value | - | number\ | string\ | boolean | - | void 0 |
| selectable | - | boolean | - | true |  |  |
| disabled | - | boolean | - | false |  |  |
| activated | - | boolean | - | false |  |  |
| customClass | - | array\ | object\ | string | - | void 0 |
| isSelected | - | boolean | - | void 0 |  |  |
| tooltip | - | boolean\ | object | - | false |  |
| active | - | func | - | noop |  |  |
| hover | - | func | - | noop |  |  |
| hoverOut | - | func | - | noop |  |  |
| toggle | - | func | - | noop |  |  |

### Select Group Option - Events

| Event name | Properties | Description |
|---|---|---|
| active | - | - |
| click | - | - |
| hover | - | - |
| mouseenter | - | - |
| hover-out | - | - |
| mouseleave | - | - |

### Select Group Option - Slots

| Name | Description | Bindings |
|---|---|---|
| inner-option | - | - |

## Select Multiline Option API

### Select Multiline Option - Props

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| id | - | string | - | void 0 |  |  |
| option | - | object | - | - |  |  |
| display | - | string | - | void 0 |  |  |
| value | - | number\ | string\ | boolean | - | void 0 |
| selectable | - | boolean | - | true |  |  |
| disabled | - | boolean | - | false |  |  |
| activated | - | boolean | - | false |  |  |
| customClass | - | array\ | object\ | string | - | void 0 |
| isSelected | - | boolean | - | void 0 |  |  |
| tooltip | - | boolean\ | object | - | false |  |
| active | - | func | - | noop |  |  |
| hover | - | func | - | noop |  |  |
| hoverOut | - | func | - | noop |  |  |
| toggle | - | func | - | noop |  |  |

### Select Multiline Option - Events

| Event name | Properties | Description |
|---|---|---|
| active | - | - |
| click | - | - |
| hover | - | - |
| mouseenter | - | - |
| hover-out | - | - |
| mouseleave | - | - |

### Select Multiline Option - Slots

| Name | Description | Bindings |
|---|---|---|
| inner-option | - | - |
| title | - | - |
| desc | - | - |

## Select No Match Option API

### Select No Match Option - Props

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| id | - | string | - | void 0 |  |  |
| option | - | object | - | - |  |  |
| display | - | string | - | void 0 |  |  |
| value | - | number\ | string\ | boolean | - | void 0 |
| selectable | - | boolean | - | true |  |  |
| disabled | - | boolean | - | false |  |  |
| activated | - | boolean | - | false |  |  |
| customClass | - | array\ | object\ | string | - | void 0 |
| isSelected | - | boolean | - | void 0 |  |  |
| tooltip | - | boolean\ | object | - | false |  |
| active | - | func | - | noop |  |  |
| hover | - | func | - | noop |  |  |
| hoverOut | - | func | - | noop |  |  |
| toggle | - | func | - | noop |  |  |

### Select No Match Option - Events

| Event name | Properties | Description |
|---|---|---|
| active | - | - |
| click | - | - |
| hover | - | - |
| mouseenter | - | - |
| hover-out | - | - |
| mouseleave | - | - |

### Select No Match Option - Slots

| Name | Description | Bindings |
|---|---|---|
| inner-option | - | - |

## Single Select API

### Single Select - Props

``

``

``

****

****

****
****

****``
****``********

****

``
``

****

****

****``

****

****

``````

````````

| Prop name | Description | Type | Values | Default |  |  |  |
|---|---|---|---|---|---|---|---|
| subscribeField | Subscribe specific register-key form-item on ancestor | string | - | void 0 |  |  |  |
| activeFormItem | do not register on form-item | boolean | - | true |  |  |  |
| enterKey | used for enterkeyhint attribute, and will change behavior when enter key is pressed | string | - | void 0 |  |  |  |
| boundaryComponentName | - | string | - | 'PortalTarget' |  |  |  |
| iconType | - | string | - | ICON_TYPE.FOLLOW_MANAGER |  |  |  |
| v-model | Selected option's value. | array\ | number\ | string\ | boolean | - | void 0 |
| id | id for this component. | string | - | function() { return syno-${this.uuid};} |  |  |  |
| name | Name for this select. | string | - | '' |  |  |  |
| width | The component's width. | number\ | string | - | 250 |  |  |
| maxHeight | Max height of the dropdown menu. | number\ | string | - | 200 |  |  |
| dropdownWidth | Dropdown menu's width. | string\ | number | - | void 0 |  |  |
| dropdownOffset | Dropdown menu's position offset | array | - | [0, 1] |  |  |  |
| customDropdownCls | Class names which the dropdown menu will have. | string | - | '' |  |  |  |
| disabled | If true, the select component will be disabled. | boolean | - | false |  |  |  |
| filter | Custom filter function which will be called when trigger search.If this prop is provided, the default filter function will be ignored.Type: `(display: string, currentOptions: Options[], queryAction: 'all' \ | 'keyword') => Options[]` | func | - | void 0 |  |  |
| search | If true, the select will become search component.See: 'Search' example. | func | - | undefined |  |  |  |
| align | How the dropdown menu should be aligned.Options: ['c', 't', 'b', 'l', 'r', 'tl', 'tr', 'bl', 'br'].Example: tl-&gt;bl means the top-left side of the menu will be stuck to the bottom-left side of the select. | string | - | 'tl->bl' |  |  |  |
| minSearchChar | The searching function of the component will be triggered only if the length of input-field's value is larger than this prop. | number\ | string | - | 1 |  |  |
| loadingText | Text which will be displayed when dropdown menu is loading. | string | - | function() { return this._i18n('uicommon', 'searching');} |  |  |  |
| notFoundText | The text which will be displayed when no item is found. | string | - | function () { return this._i18n('search', 'no_search_result');} |  |  |  |
| tooltip | If true, each item in the dropdown menu will have a tooltip. | boolean | - | false |  |  |  |
| mapOptionToTooltip | Map menu option to tooltip's content.It will be given a menu option as param and should return a string.If this prop is not provided, then the tooltip's content will be option's display field. | func | - | null |  |  |  |
| shouldMenuClose | A function will will be called before the dropdown menu close.If this function return true, then the dropdown menu won't be closed. | func | - | () => true |  |  |  |
| options | The function that generate options for the component.It can be an array with options too. | object\ | array | - | () => [] |  |  |
| groupOptions | when you use options as object, it will turns to use grouped options to displayand you can use this props to specify the group option to usefor example: if options has been given by { 'objKey': [{ label: 'Red', value: 'red' }] }and you can use groupOptions: { 'objKey': { label: 'Group String' } } to specify the display string | object | - | () => {} |  |  |  |
| clearable | If true, there will be a clear button in the select. | boolean | - | false |  |  |  |
| editable | Input text will be editable | boolean | - | undefined |  |  |  |
| hideTrigger | If true, the arrow-down icon at the right-side of the select will be hidden. | boolean | - | undefined |  |  |  |
| position | Positon strategy for the dropdown menu. | string | - | 'absolute' |  |  |  |
| displayField | Field name of option label | string | - | 'label' |  |  |  |
| valueField | Field name of option value | string | - | 'value' |  |  |  |
| closeOnSelect | Close dropdown menu when user click option | boolean | - | true |  |  |  |
| placeholder | The placeholder which will be shown when no option is selected. | string | - | '' |  |  |  |
| nullValue | The Null Value, use this value if you want to set select back to empty state | string\ | array | - | null |  |  |
| inputScrollable | - | boolean | - | false |  |  |  |
| inputTooltip | - | object | - | disabled: true, |  |  |  |
| useOptionSlot | - | boolean\ | string | - | void 0 |  |  |
| triggerQueryAction | The action to execute when the trigger is clicked. default is 'all'Options: ['all', 'keyword'] | string | - | 'all' |  |  |  |
| caseSensitive | If true, when the component is editable, the comparison will be case sensitive. | boolean | - | false |  |  |  |
| virtualScrollbar | If true, this component will use virtual scroll into dropdown | boolean | - | false |  |  |  |
| virtualItemHeight | virtual scroll info, item height of option | number | - | 28 |  |  |  |
| virtualBufferSize | Virtual Scroll buffer size | number | - | 200 |  |  |  |
| showNotFound | - | boolean | - | true |  |  |  |
| showDropdown | - | boolean | - | true |  |  |  |
| displayTextFormat | - | object | - | { group: '{group}:{option}', option: '{option}', delimiter: this._i18n('common', 'comma'),} |  |  |  |
| displayMode | - | string | label, text, none | 'none' |  |  |  |
| advanced | - | boolean\ | object | - | false |  |  |
| searchIconActive | true to distinguish advanced search conditions are set in advance panel.the search icon would separate in two parts, blue for search icon, grey for dropdown icon. | boolean | - | false |  |  |  |
| defaultOption | - | object\ | func\ | string | - | () => vBaseOption |  |
| customIcon | - | string | search, filter, custom, none | void 0 |  |  |  |
| forceSelection | Force select last valid value back when blur with editable mode. | boolean | - | false |  |  |  |
| selectOnFocus | select text when focus on textfield | boolean | - | true |  |  |  |

### Single Select - Methods

### setLoading

show busy status on search dropdown

| Param name | Type | Description |
|---|---|---|
| status | boolean | - |

### Single Select - Events

****``

****``

****``

****````

****``

****``

| Event name | Properties | Description |
|---|---|---|
| focus-next-field | - | - |
| focus-prev-field | - | - |
| blur | - | - |
| display-changed | - | - |
| dropdown-shown | undefined mixed - undefined | Emitted when dropdown shown. |
| dropdown-hidden | undefined mixed - undefined | Emitted when dropdown hidden. |
| is-active | isActive Boolean - undefined | Emitted when the select's active status is changed. |
| close-dropdown | - | - |
| click-icon | - | Emitted when icon is clicked. |
| click-advanced-icon | - | Emitted when right advanced icon is clicked. |
| clear | - | - |
| input | value any - It will be an array if multiple is true. | Emitted when selected option is changed. |
| internal-select | index object - index of selected option | Triggers when the option is clicked. |
| select | opt object - selected option | Triggers when the option is clicked. |
| focus | - | - |

### Single Select - Slots

| Name | Description | Bindings |
|---|---|---|
| input | - |  |
| icon | - |  |
| input-right | - | - |
| advanced-menu | - | - |
| advanced-panel | - | - |
| dropdown | - |  |
| default | - | - |
