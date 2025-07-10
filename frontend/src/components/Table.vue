<script setup>
import { ref } from 'vue'
import Record from '@/views/Record.vue'
import Summary from '@/views/Summary.vue'

const activeTab = ref('tab1')
</script>

<template>
  <div class="nav-bar">
    <button :class="{ active: activeTab === 'tab1' }" @click="activeTab = 'tab1'">记录</button>
    <button :class="{ active: activeTab === 'tab2' }" @click="activeTab = 'tab2'">总结</button>
  </div>
  <div class="tab-content" v-if="activeTab === 'tab1'">
    <Record/>
  </div>
  <div class="tab-content" v-else>
    <Summary/>
  </div>
</template>

<style scoped>
.nav-bar {
  display: flex;
  padding: 16px 0 0 24px;
  border-bottom: 1px solid #dddddd;
}
.nav-bar button {
  background: none;
  border: none;
  padding: 8px 20px;
  font-size: 16px;
  cursor: pointer;
  border-radius: 4px 4px 0 0;
  color: #666;
}
.nav-bar button.active {
  background: #409eff;
  color: #fff;
}
.tab-content {
  flex: 1 1 0;
  padding: 10px 24px 0 0;
  /* background-color: #409eff; */
  overflow-y: overlay;
}
.tab-content::-webkit-scrollbar {
  width: 4px;
  background: transparent;
}
.tab-content::-webkit-scrollbar-thumb {
  background: rgba(0,0,0,0.15);
  border-radius: 4px;
}
</style>