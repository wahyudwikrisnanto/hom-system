const fs = require('fs');
const path = require('path');

const dir = './gym-frontend/components/setting';
const files = [
  'AdminFee.vue',
  'BuddyReferral.vue',
  'Complimentary.vue',
  'MinimumDownPayment.vue',
  'PtCuttingApprovalPolicy.vue',
  'TransferPolicy.vue',
  'AddOnPolicy.vue',
  'form.vue'
];

files.forEach(f => {
  let content = fs.readFileSync(path.join(dir, f), 'utf-8');
  
  // Replace the save button area
  content = content.replace(/<template v-if="canEdit">[\s\S]*?<\/template>/, '');
  content = content.replace(/<SharedUiSeparator class="my-4" \/>[\s\S]*?<\/div>/, '');
  
  // Remove ApprovalRequestDialog
  content = content.replace(/<ApprovalRequestDialog[\s\S]*?\/>/, '');

  // We add defineExpose to the script setup
  // Some use `function nextSubSettings()` or `setting.toJSON()` or similar
  
  if (content.includes('defineExpose')) {
     return;
  }

  let exposeFunc = '';
  if (f === 'form.vue') {
     exposeFunc = `
defineExpose({
  getSettingId: () => props.setting.id,
  getSubSettings: () => setting.toJSON(),
  isDirty: () => setting.isDirty
});
`;
  } else {
     exposeFunc = `
defineExpose({
  getSettingId: () => props.setting?.id,
  getSubSettings: () => nextSubSettings ? nextSubSettings() : []
});
`;
  }
  
  content = content.replace(/<\/script>/, exposeFunc + '\n</script>');

  fs.writeFileSync(path.join(dir, f), content, 'utf-8');
});
console.log('Done');
